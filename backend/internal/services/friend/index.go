package friend

import (
	"context"
	"time"

	"befriend/internal/model"
	repoFriend "befriend/internal/repositories/friend"
	"befriend/internal/repositories/tx"
	"befriend/internal/services/personality_version"
)

type FriendService interface {
	Create(ctx context.Context, payload CreatePayload) (*model.Friend, error)
	GetByID(ctx context.Context, id string) (*model.Friend, error)
	GetByUserID(ctx context.Context, userID string) (*model.Friend, error)
	GetProfile(ctx context.Context, userID string) (*ProfileResponse, error)
	SetCurrentVersion(ctx context.Context, friendID, versionID string) error
	ListDueForEvolution(ctx context.Context, now time.Time, limit int) ([]model.Friend, error)
	SetNextEvolutionAt(ctx context.Context, friendID string, next time.Time) error
}

type friendService struct {
	txRepo                    tx.TxRepo
	friendRepo                repoFriend.FriendRepo
	personalityVersionService personality_version.PersonalityVersionService
}

func NewFriendService(txRepo tx.TxRepo,
	friendRepo repoFriend.FriendRepo,
	personalityVersionService personality_version.PersonalityVersionService) FriendService {
	return &friendService{
		txRepo:                    txRepo,
		friendRepo:                friendRepo,
		personalityVersionService: personalityVersionService,
	}
}
