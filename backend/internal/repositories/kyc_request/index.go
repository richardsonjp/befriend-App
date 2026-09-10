package kyc_request

import (
	"context"
	"befriend/internal/model"
	"befriend/pkg/clients/db"
)

type KycRequestRepo interface {
	Create(ctx context.Context, m *model.KycRequest) error
	Update(ctx context.Context, m model.KycRequest, updatedFields ...string) (int64, error)
}

type kycRequestRepo struct {
	dbdget db.DBGormDelegate
}

func NewKycRequestRepo(dbdget db.DBGormDelegate) KycRequestRepo {
	return &kycRequestRepo{
		dbdget: dbdget,
	}
}
