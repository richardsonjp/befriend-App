package personality_version

import (
	"context"
	"encoding/json"
	"time"

	"befriend/internal/model"
	repoPersonalityVersion "befriend/internal/repositories/personality_version"
	"befriend/internal/repositories/tx"
)

type PersonalityVersionService interface {
	CreateInitial(ctx context.Context, friendID string) (*model.PersonalityVersion, error)
	GetByID(ctx context.Context, id string) (*model.PersonalityVersion, error)
	GetLatestByFriend(ctx context.Context, friendID string) (*model.PersonalityVersion, error)
	ClaimDue(ctx context.Context, limit int, lockFor time.Duration) ([]model.PersonalityVersion, error)
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
