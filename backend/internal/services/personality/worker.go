package personality

import (
	"context"
	"encoding/json"
	stderrors "errors"
	"fmt"
	"time"

	"befriend/config"
	"befriend/internal/model"
	"befriend/pkg/clients/openrouter"
	"befriend/pkg/utils/astro"
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
	ok, retryAt, err := s.llmBudgetRepo.TryConsume(ctx, now, config.Config.LLM.MinuteCap, config.Config.LLM.DailyCap)
	if err != nil {
		s.fail(ctx, job, fmt.Errorf("check LLM budget: %w", err))
		return
	}
	if !ok {
		s.deferJob(ctx, job, retryAt, "LLM request budget reached")
		return
	}

	input, err := s.promptInput(ctx, job.FriendID)
	if err != nil {
		s.fail(ctx, job, fmt.Errorf("load prompt input: %w", err))
		return
	}
	system, user := Prompt(*input)
	resp, err := s.openRouter.Complete(ctx, openrouter.Request{
		System:      system,
		User:        user,
		SchemaName:  SchemaName,
		Schema:      ResponseSchema(),
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
	personality, phrasebook, err := Validate(&generated)
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
		return s.friendService.SetCurrentVersion(ctx, job.FriendID, job.ID)
	})
	if err != nil {
		// Most likely the claim expired and another pass owns the row now; leave it to that pass.
		logs.Log.Errorf("personality %s v%d: store result: %v", job.FriendID, job.Version, err)
		return
	}
	logs.Log.Infof("personality %s v%d ready (model %s)", job.FriendID, job.Version, resp.Model)
}

func (s *personalityService) promptInput(ctx context.Context, friendID string) (*PromptInput, error) {
	f, err := s.friendService.GetByID(ctx, friendID)
	if err != nil {
		return nil, err
	}
	answers, err := s.onboardingService.GetAnsweredQuestions(ctx, f.UserID)
	if err != nil {
		return nil, err
	}

	input := &PromptInput{
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
	return input, nil
}

// fail records a failed attempt, retried with backoff. A job cut short by shutdown is deferred instead, to
// run again right away on the next start.
func (s *personalityService) fail(ctx context.Context, job *model.PersonalityVersion, cause error) {
	if ctx.Err() != nil {
		s.deferJob(ctx, job, time.Now(), fmt.Sprintf("interrupted by shutdown: %v", cause))
		return
	}
	retryAt := time.Now().Add(retryDelay(job.Attempts))
	logs.Log.Errorf("personality %s v%d attempt %d failed, retry at %s: %v", job.FriendID, job.Version, job.Attempts, retryAt.Format(time.RFC3339), cause)
	if err := s.personalityVersionService.Fail(context.WithoutCancel(ctx), job, retryAt, cause.Error()); err != nil {
		logs.Log.Errorf("personality %s v%d: record failure: %v", job.FriendID, job.Version, err)
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
