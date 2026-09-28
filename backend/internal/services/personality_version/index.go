package personality_version

import (
	"context"
	"encoding/json"
	"time"

	"befriend/internal/model"
	"befriend/internal/model/enum"
	repoPersonalityVersion "befriend/internal/repositories/personality_version"
	"befriend/internal/repositories/tx"
)

type PersonalityVersionService interface {
	CreateInitial(ctx context.Context, friendID string) (*model.PersonalityVersion, error)
	// CreateEvolution queues the next version for a weekly evolution; nil when the latest version isn't ready yet
	// (still generating, or failed and waiting to retry).
	CreateEvolution(ctx context.Context, friendID string) (*model.PersonalityVersion, error)
	// CreateReskin queues a phrasebook for the picked skin (nil = built-in), superseding any reskin still waiting.
	CreateReskin(ctx context.Context, friendID string, skinID *string) (*model.PersonalityVersion, error)
	// GetActiveReskin is the skin pick still being written for; nil when there is none.
	GetActiveReskin(ctx context.Context, friendID string) (*model.PersonalityVersion, error)
	AbandonReskins(ctx context.Context, friendID, reason string) error
	// Abandon ends a claimed job without a retry.
	Abandon(ctx context.Context, job *model.PersonalityVersion, reason string) error
	GetByID(ctx context.Context, id string) (*model.PersonalityVersion, error)
	GetLatestByFriend(ctx context.Context, friendID string) (*model.PersonalityVersion, error)
	// ClaimDue takes due evolutions (the evolve job).
	ClaimDue(ctx context.Context, limit int, lockFor time.Duration) ([]model.PersonalityVersion, error)
	// ClaimForFriend takes the friend's newest claimable job of this reason for a request that waits on it.
	ClaimForFriend(ctx context.Context, friendID string, reason enum.PersonalityReason, lockFor time.Duration) (*model.PersonalityVersion, error)
	MarkReady(ctx context.Context, job *model.PersonalityVersion, llmModel string, vocabularyVersion int, personality, phrasebook json.RawMessage) error
	Defer(ctx context.Context, job *model.PersonalityVersion, until time.Time, reason string) error
	Fail(ctx context.Context, job *model.PersonalityVersion, retryAt time.Time, reason string) error
}

type personalityVersionService struct {
	txRepo                 tx.TxRepo
	personalityVersionRepo repoPersonalityVersion.PersonalityVersionRepo
}

func NewPersonalityVersionService(txRepo tx.TxRepo,
	personalityVersionRepo repoPersonalityVersion.PersonalityVersionRepo) PersonalityVersionService {
	return &personalityVersionService{
		txRepo:                 txRepo,
		personalityVersionRepo: personalityVersionRepo,
	}
}
