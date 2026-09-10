package verification_code

import (
	"context"
	"go-skeleton/internal/model"
	"go-skeleton/pkg/clients/db"
)

type VerificationCodeRepo interface {
	Create(ctx context.Context, m *model.VerificationCode) (*model.VerificationCode, error)
	Get(ctx context.Context, tableType, userID, code string) (*model.VerificationCode, error)
	Delete(ctx context.Context, tableType, userID, code string) error
}

type verificationCodeRepo struct {
	dbdget db.DBGormDelegate
}

func NewVerificationCodeRepo(dbdget db.DBGormDelegate) VerificationCodeRepo {
	return &verificationCodeRepo{
		dbdget: dbdget,
	}
}
