package personality_version

import (
	"context"

	"befriend/internal/model"
	"befriend/pkg/clients/db"
)

type PersonalityVersionRepo interface {
	Create(ctx context.Context, m *model.PersonalityVersion) (*model.PersonalityVersion, error)
	GetLatestByFriend(ctx context.Context, friendID string) (*model.PersonalityVersion, error)
}

type personalityVersionRepo struct {
	dbdget db.DBGormDelegate
}

func NewPersonalityVersionRepo(dbdget db.DBGormDelegate) PersonalityVersionRepo {
	return &personalityVersionRepo{
		dbdget: dbdget,
	}
}
