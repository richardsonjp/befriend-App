package personality_version

import (
	"context"
	"encoding/json"
	"time"
	"unicode/utf8"

	"befriend/internal/model"
	"befriend/internal/model/enum"
	repoPersonalityVersion "befriend/internal/repositories/personality_version"
)

const maxErrorLength = 500

// CreateInitial queues version 1 for generation; the worker picks up pending rows.
func (s *personalityVersionService) CreateInitial(ctx context.Context, friendID string) (*model.PersonalityVersion, error) {
	return s.personalityVersionRepo.Create(ctx, &model.PersonalityVersion{
		FriendID: friendID,
		Version:  1,
		Status:   enum.PERSONALITY_PENDING,
		Reason:   enum.REASON_ONBOARDING,
	})
}

func (s *personalityVersionService) CreateEvolution(ctx context.Context, friendID string) (*model.PersonalityVersion, error) {
	latest, err := s.personalityVersionRepo.GetLatestByFriend(ctx, friendID)
	if err != nil {
		return nil, err
	}
	if latest.Status != enum.PERSONALITY_READY {
		return nil, nil
	}
	next, err := s.personalityVersionRepo.NextVersion(ctx, friendID)
	if err != nil {
		return nil, err
	}
	return s.personalityVersionRepo.Create(ctx, &model.PersonalityVersion{
		FriendID: friendID,
		Version:  next,
		Status:   enum.PERSONALITY_PENDING,
		Reason:   enum.REASON_EVOLUTION,
	})
}

// CreateReskin queues a phrasebook for skinID (nil = built-in), superseding any reskin still waiting.
func (s *personalityVersionService) CreateReskin(ctx context.Context, friendID string, skinID *string) (*model.PersonalityVersion, error) {
	if err := s.AbandonReskins(ctx, friendID, "superseded by another skin pick"); err != nil {
		return nil, err
	}
	next, err := s.personalityVersionRepo.NextVersion(ctx, friendID)
	if err != nil {
		return nil, err
	}
	return s.personalityVersionRepo.Create(ctx, &model.PersonalityVersion{
		FriendID: friendID,
		Version:  next,
		Status:   enum.PERSONALITY_PENDING,
		Reason:   enum.REASON_RESKIN,
		SkinID:   skinID,
	})
}

func (s *personalityVersionService) GetActiveReskin(ctx context.Context, friendID string) (*model.PersonalityVersion, error) {
	return s.personalityVersionRepo.GetActiveReskin(ctx, friendID)
}

func (s *personalityVersionService) AbandonReskins(ctx context.Context, friendID, reason string) error {
	return s.personalityVersionRepo.AbandonReskins(ctx, friendID, truncate(reason), time.Now())
}

// Abandon ends a claimed job for good (a reskin that failed: the user keeps the skin they had).
func (s *personalityVersionService) Abandon(ctx context.Context, job *model.PersonalityVersion, reason string) error {
	return s.personalityVersionRepo.Reschedule(ctx, claimOf(job), enum.PERSONALITY_ABANDONED, time.Now(), truncate(reason), true, time.Now())
}

func (s *personalityVersionService) GetByID(ctx context.Context, id string) (*model.PersonalityVersion, error) {
	return s.personalityVersionRepo.GetByID(ctx, id)
}

func (s *personalityVersionService) GetLatestByFriend(ctx context.Context, friendID string) (*model.PersonalityVersion, error) {
	return s.personalityVersionRepo.GetLatestByFriend(ctx, friendID)
}

// ClaimDue takes up to limit due jobs and locks them for lockFor.
func (s *personalityVersionService) ClaimDue(ctx context.Context, limit int, lockFor time.Duration) ([]model.PersonalityVersion, error) {
	now := time.Now()
	return s.personalityVersionRepo.ClaimDue(ctx, now, limit, now.Add(lockFor))
}

func (s *personalityVersionService) MarkReady(ctx context.Context, job *model.PersonalityVersion, llmModel string, vocabularyVersion int, personality, phrasebook json.RawMessage) error {
	return s.personalityVersionRepo.MarkReady(ctx, claimOf(job), llmModel, vocabularyVersion, personality, phrasebook, time.Now())
}

// Defer puts a claimed job back to pending without counting the attempt (budget or rate limit).
func (s *personalityVersionService) Defer(ctx context.Context, job *model.PersonalityVersion, until time.Time, reason string) error {
	return s.personalityVersionRepo.Reschedule(ctx, claimOf(job), enum.PERSONALITY_PENDING, until, truncate(reason), false, time.Now())
}

// Fail marks a claimed job failed; it is retried at retryAt.
func (s *personalityVersionService) Fail(ctx context.Context, job *model.PersonalityVersion, retryAt time.Time, reason string) error {
	return s.personalityVersionRepo.Reschedule(ctx, claimOf(job), enum.PERSONALITY_FAILED, retryAt, truncate(reason), true, time.Now())
}

// claimOf reads the claim ClaimDue returned; a job without a lock never matches a row.
func claimOf(job *model.PersonalityVersion) repoPersonalityVersion.Claim {
	claim := repoPersonalityVersion.Claim{ID: job.ID}
	if job.LockedUntil != nil {
		claim.LockedUntil = *job.LockedUntil
	}
	return claim
}

func truncate(s string) string {
	if utf8.RuneCountInString(s) <= maxErrorLength {
		return s
	}
	return string([]rune(s)[:maxErrorLength])
}
