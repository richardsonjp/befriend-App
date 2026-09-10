package pairing_code

import (
	"context"
	"time"

	"befriend/internal/model"
	"befriend/pkg/clients/db"
)

type PairingCodeRepo interface {
	Create(ctx context.Context, m *model.PairingCode) error
	// GetByCodeHash locks the row when forUpdate is set (call inside a transaction).
	GetByCodeHash(ctx context.Context, codeHash string, forUpdate bool) (*model.PairingCode, error)
	Confirm(ctx context.Context, id, userID string, at time.Time) error
	MarkConsumed(ctx context.Context, id string, at time.Time) error
}

type pairingCodeRepo struct {
	dbdget db.DBGormDelegate
}

func NewPairingCodeRepo(dbdget db.DBGormDelegate) PairingCodeRepo {
	return &pairingCodeRepo{
		dbdget: dbdget,
	}
}
