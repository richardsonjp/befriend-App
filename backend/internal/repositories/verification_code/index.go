package verification_code

import (
	"context"

	"befriend/internal/model"
	"befriend/pkg/clients/db"
)

type VerificationCodeRepo interface {
	Create(ctx context.Context, m *model.VerificationCode) (*model.VerificationCode, error)
	GetLatest(ctx context.Context, tableType, userID string) (*model.VerificationCode, error)
	IncrementAttempts(ctx context.Context, id string) error
	DeleteAll(ctx context.Context, tableType, userID string) error
}

type verificationCodeRepo struct {
	dbdget db.DBGormDelegate
}

func NewVerificationCodeRepo(dbdget db.DBGormDelegate) VerificationCodeRepo {
	return &verificationCodeRepo{
		dbdget: dbdget,
	}
}
