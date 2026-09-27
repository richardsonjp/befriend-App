package personality

import (
	"context"
	"encoding/json"
	stderrors "errors"
	"fmt"
	"time"

	"befriend/config"
	"befriend/internal/model"
	"befriend/internal/model/enum"
	"befriend/pkg/clients/openrouter"
	"befriend/pkg/utils/astro"
	"befriend/pkg/utils/errors"
	"befriend/pkg/utils/logs"
	"befriend/pkg/utils/vocabulary"
)

// claimLockFor must outlast one job (OpenRouter's client timeout is 3 minutes); an expired lock lets
// another pass reclaim a job whose worker died.
const claimLockFor = 5 * time.Minute

// ProcessDue claims one job at a time, so a claim's lock only has to outlast its own job.
func (s *personalityService) ProcessDue(ctx context.Context, limit int) (int, error) {
	if s.openRouter == nil {
		return 0, nil
	}
	for done := 0; done < limit; done++ {
		if ctx.Err() != nil {
			return done, nil
		}
		jobs, err := s.personalityVersionService.ClaimDue(ctx, 1, claimLockFor)
		if err != nil {
			return done, err
		}
		if len(jobs) == 0 {
			return done, nil
		}
		s.process(ctx, &jobs[0])
	}
	return limit, nil
}

// process runs one claimed job to an outcome recorded on its row: ready, deferred (budget, rate limit or
// shutdown; no attempt counted) or failed (retried with backoff). Outcomes are written even when ctx was
// cancelled mid-job, so a shutdown doesn't leave the row locked.
func (s *personalityService) process(ctx context.Context, job *model.PersonalityVersion) {
	defer func() {
		if r := recover(); r != nil {
			s.fail(ctx, job, fmt.Errorf("panic: %v", r))
		}
	}()

	now := time.Now()
	dailyCap := config.Config.LLM.DailyCap
	if job.Reason == enum.REASON_EVOLUTION {
		dailyCap -= config.Config.LLM.OnboardingReserve
	}
	ok, retryAt, err := s.consumeBudget(ctx, now, config.Config.LLM.MinuteCap, dailyCap)
	if err != nil {
		s.fail(ctx, job, fmt.Errorf("check LLM budget: %w", err))
		return
	}
	if !ok {
		s.deferJob(ctx, job, retryAt, "LLM request budget reached")
		return
	}

	input, err := s.promptInput(ctx, job)
	if err != nil {
		s.fail(ctx, job, fmt.Errorf("load prompt input: %w", err))
		return
	}
	system, user := Prompt(*input)
	resp, err := s.openRouter.Complete(ctx, openrouter.Request{
		System:      system,
		User:        user,
		SchemaName:  SchemaName,
		Schema:      ResponseSchema(input.Skin),
		MaxTokens:   MaxTokens,
		Temperature: Temperature,
	})
	var rateLimited *openrouter.RateLimitError
	if stderrors.As(err, &rateLimited) {
		s.deferJob(ctx, job, now.Add(rateLimited.RetryAfter), rateLimited.Error())
		return
	}
	if err != nil {
		s.fail(ctx, job, err)
		return
	}

	var generated Generated
	if err := json.Unmarshal([]byte(resp.Content), &generated); err != nil {
		s.fail(ctx, job, fmt.Errorf("model returned invalid JSON: %w", err))
		return
	}
	if job.Reason == enum.REASON_RESKIN {
		// A new look, the same friend: the model's copy of the personality is discarded, so it can't fail the job.
		generated.Personality = *input.Previous
	}
	Repair(&generated, input.Skin)
	personality, phrasebook, err := Validate(&generated, input.Skin)
	if err != nil {
		s.fail(ctx, job, fmt.Errorf("model output rejected: %w", err))
		return
	}
	personalityJSON, err := json.Marshal(personality)
	if err != nil {
		s.fail(ctx, job, err)
		return
	}
	phrasebookJSON, err := json.Marshal(phrasebook)
	if err != nil {
		s.fail(ctx, job, err)
		return
	}

	err = s.txRepo.Run(context.WithoutCancel(ctx), func(ctx context.Context) error {
		if err := s.personalityVersionService.MarkReady(ctx, job, resp.Model, vocabulary.Version, personalityJSON, phrasebookJSON); err != nil {
			return err
		}
		if err := s.friendService.SetCurrentVersion(ctx, job.FriendID, job.ID); err != nil {
			return err
		}
		if job.Reason != enum.REASON_RESKIN {
			return s.reskinIfSwitched(ctx, job, input)
		}
		// The phrasebook fits the picked skin now: switch to it. Fails if the grant was revoked meanwhile.
		if err := s.userService.UpdateSkin(ctx, input.userID, job.SkinID); err != nil {
			return err
		}
		return s.skinService.NotifyUser(ctx, input.userID)
	})
	if errors.Is(err, "SKIN_NOT_FOUND") {
		s.fail(ctx, job, fmt.Errorf("the picked skin is no longer granted"))
		return
	}
	if err != nil {
		// Most likely the claim expired and another pass owns the row now; leave it to that pass.
		logs.Log.Errorf("personality %s v%d: store result: %v", job.FriendID, job.Version, err)
		return
	}
	logs.Log.Infof("personality %s v%d ready (%s, model %s)", job.FriendID, job.Version, job.Reason, resp.Model)
}

func (s *personalityService) promptInput(ctx context.Context, job *model.PersonalityVersion) (*PromptInput, error) {
	f, err := s.friendService.GetByID(ctx, job.FriendID)
	if err != nil {
		return nil, err
	}
	answers, err := s.onboardingService.GetAnsweredQuestions(ctx, f.UserID)
	if err != nil {
		return nil, err
	}

	input := &PromptInput{
		userID:       f.UserID,
		FriendName:   f.Name,
		UserNickname: f.UserNickname,
		Chart: astro.Chart{
			WesternSign:     f.WesternSign,
			ChineseAnimal:   f.ChineseAnimal,
			ChineseElement:  f.ChineseElement,
			ChinesePolarity: f.ChinesePolarity,
			FengShuiStar:    f.FengShuiStar,
			FengShuiElement: f.FengShuiElement,
		},
	}
	if f.BirthCity != nil {
		input.BirthCity = *f.BirthCity
	}
	if f.BirthCountry != nil {
		input.BirthCountry = *f.BirthCountry
	}
	for _, a := range answers {
		input.Answers = append(input.Answers, AnsweredQuestion{Question: a.Question, Answer: a.Answer})
	}

	// A reskin writes for the picked skin; everything else for the skin the user has on now.
	skinID := job.SkinID
	if job.Reason != enum.REASON_RESKIN {
		owner, err := s.userService.GetUserByID(ctx, f.UserID)
		if err != nil {
			return nil, err
		}
		skinID = owner.SkinID
	}
	input.skinID = skinID
	if input.Skin, err = s.skinService.Vocabulary(ctx, skinID); err != nil {
		return nil, err
	}

	switch job.Reason {
	case enum.REASON_EVOLUTION:
		if err := s.addEvolutionInput(ctx, f, input); err != nil {
			return nil, err
		}
	case enum.REASON_RESKIN:
		if input.Previous, err = s.currentPersonality(ctx, f); err != nil {
			return nil, err
		}
		input.Reskin = true
	}
	return input, nil
}

// reskinIfSwitched catches a skin picked while this job ran for the old one (the pick applies at once while the
// friend is hatching): the lines just written don't fit, so write them again for the skin the user has now.
func (s *personalityService) reskinIfSwitched(ctx context.Context, job *model.PersonalityVersion, input *PromptInput) error {
	owner, err := s.userService.GetUserByID(ctx, input.userID)
	if err != nil {
		return err
	}
	if sameSkin(owner.SkinID, input.skinID) {
		return nil
	}
	_, err = s.personalityVersionService.CreateReskin(ctx, job.FriendID, owner.SkinID)
	return err
}

func sameSkin(a, b *string) bool {
	return (a == nil && b == nil) || (a != nil && b != nil && *a == *b)
}

func (s *personalityService) currentPersonality(ctx context.Context, f *model.Friend) (*Personality, error) {
	if f.CurrentVersionID == nil {
		return nil, fmt.Errorf("friend %s has no personality yet", f.ID)
	}
	current, err := s.personalityVersionService.GetByID(ctx, *f.CurrentVersionID)
	if err != nil {
		return nil, err
	}
	if current.Personality == nil {
		return nil, fmt.Errorf("personality version %s has no content", current.ID)
	}
	var previous Personality
	if err := json.Unmarshal(current.Personality.Data, &previous); err != nil {
		return nil, err
	}
	return &previous, nil
}

// addEvolutionInput gives an evolution the friend's current personality and its user's recent activity.
func (s *personalityService) addEvolutionInput(ctx context.Context, f *model.Friend, input *PromptInput) error {
	previous, err := s.currentPersonality(ctx, f)
	if err != nil {
		return err
	}
	input.Previous = previous

	events, err := s.triggerEventService.Recent(ctx, f.UserID, MaxActivityLines)
	if err != nil {
		return err
	}
	input.RecentActivity = activityLines(events, f.BirthTZ)
	return nil
}

// activityLines formats events for the prompt in the friend's time zone ("Mon 23:40").
func activityLines(events []model.TriggerEvent, timezone string) []ActivityLine {
	loc, err := time.LoadLocation(timezone)
	if err != nil {
		loc = time.UTC
	}
	lines := make([]ActivityLine, 0, len(events))
	for _, e := range events {
		line := ActivityLine{Kind: e.Kind, At: e.OccurredAt.In(loc).Format("Mon 15:04")}
		if e.AppName != nil {
			line.App = *e.AppName
		}
		if e.Seconds != nil {
			line.Seconds = *e.Seconds
		}
		lines = append(lines, line)
	}
	return lines
}

// fail records a failed attempt, retried with backoff. A job cut short by shutdown is deferred instead, to
// run again right away on the next start. A failed reskin isn't retried: the user keeps the skin they had,
// and their apps stop waiting for the new one.
func (s *personalityService) fail(ctx context.Context, job *model.PersonalityVersion, cause error) {
	if ctx.Err() != nil {
		s.deferJob(ctx, job, time.Now(), fmt.Sprintf("interrupted by shutdown: %v", cause))
		return
	}
	if job.Reason == enum.REASON_RESKIN {
		s.abandonReskin(ctx, job, cause)
		return
	}
	retryAt := time.Now().Add(retryDelay(job.Attempts))
	logs.Log.Errorf("personality %s v%d attempt %d failed, retry at %s: %v", job.FriendID, job.Version, job.Attempts, retryAt.Format(time.RFC3339), cause)
	if err := s.personalityVersionService.Fail(context.WithoutCancel(ctx), job, retryAt, cause.Error()); err != nil {
		logs.Log.Errorf("personality %s v%d: record failure: %v", job.FriendID, job.Version, err)
	}
}

func (s *personalityService) abandonReskin(ctx context.Context, job *model.PersonalityVersion, cause error) {
	logs.Log.Errorf("personality %s v%d reskin abandoned: %v", job.FriendID, job.Version, cause)
	err := s.txRepo.Run(context.WithoutCancel(ctx), func(ctx context.Context) error {
		if err := s.personalityVersionService.Abandon(ctx, job, cause.Error()); err != nil {
			return err
		}
		f, err := s.friendService.GetByID(ctx, job.FriendID)
		if err != nil {
			return err
		}
		return s.skinService.NotifyUser(ctx, f.UserID)
	})
	if err != nil {
		logs.Log.Errorf("personality %s v%d: abandon: %v", job.FriendID, job.Version, err)
	}
}

func (s *personalityService) deferJob(ctx context.Context, job *model.PersonalityVersion, until time.Time, reason string) {
	if err := s.personalityVersionService.Defer(context.WithoutCancel(ctx), job, until, reason); err != nil {
		logs.Log.Errorf("personality %s v%d: defer: %v", job.FriendID, job.Version, err)
	}
}

// retryDelay backs off failed generations: 5 minutes, 30 minutes, 2 hours, then every 12 hours.
// attempts counts the attempt that just failed.
func retryDelay(attempts int) time.Duration {
	switch {
	case attempts <= 1:
		return 5 * time.Minute
	case attempts == 2:
		return 30 * time.Minute
	case attempts == 3:
		return 2 * time.Hour
	default:
		return 12 * time.Hour
	}
}
