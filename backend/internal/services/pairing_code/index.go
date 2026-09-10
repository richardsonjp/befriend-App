package pairing_code

import (
	"context"
	"time"

	"befriend/internal/model"
	repoPairingCode "befriend/internal/repositories/pairing_code"
	"befriend/internal/repositories/tx"
)

type PairingCodeService interface {
	// Create starts a pairing for a Mac: a short code for its QR and a poll secret only the Mac keeps.
	Create(ctx context.Context, payload CreatePayload) (*CreateResponse, error)
	// GetPending describes a code an iPhone scanned, while it can still be confirmed.
	GetPending(ctx context.Context, code string) (*PendingResponse, error)
	// Confirm links the code to the signed-in iPhone's user.
	Confirm(ctx context.Context, code, userID string) error
	// Claim consumes a confirmed code for the Mac holding its poll secret. It returns nil, nil while the code
	// isn't confirmed yet, and PAIRING_GONE when it can never be claimed. Call it inside a transaction.
	Claim(ctx context.Context, code, pollSecret string) (*model.PairingCode, error)
	// DeleteExpired removes pairing attempts that expired more than a day ago.
	DeleteExpired(ctx context.Context, now time.Time) (int64, error)
}

type pairingCodeService struct {
	txRepo          tx.TxRepo
	pairingCodeRepo repoPairingCode.PairingCodeRepo
}

func NewPairingCodeService(txRepo tx.TxRepo,
	pairingCodeRepo repoPairingCode.PairingCodeRepo) PairingCodeService {
	return &pairingCodeService{
		txRepo:          txRepo,
		pairingCodeRepo: pairingCodeRepo,
	}
}
