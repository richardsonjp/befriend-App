package personality_version

import (
	"context"

	"befriend/internal/model"
	repoPersonalityVersion "befriend/internal/repositories/personality_version"
	"befriend/internal/repositories/tx"
)

type PersonalityVersionService interface {
	CreateInitial(ctx context.Context, friendID string) (*model.PersonalityVersion, error)
	GetLatestByFriend(ctx context.Context, friendID string) (*model.PersonalityVersion, error)
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
