package verification_code

import (
	"context"
	"go-skeleton/internal/model"
	"go-skeleton/internal/repositories/tx"
	"go-skeleton/internal/repositories/verification_code"
	"go-skeleton/pkg/clients/email"
)

type VerificationCodeService interface {
	Create(ctx context.Context, payload CreatePayload) (*model.VerificationCode, error)
	SendVerificationEmail(ctx context.Context, payload CreatePayload) error
	Delete(ctx context.Context, payload DeletePayload) error
}

type verificationCodeService struct {
	txRepo               tx.TxRepo
	verificationCodeRepo verification_code.VerificationCodeRepo
	smtpClient           email.EmailSender
}

func NewVerificationCodeService(txRepo tx.TxRepo,
	verificationCodeRepo verification_code.VerificationCodeRepo,
	smtpClient email.EmailSender) VerificationCodeService {
	return &verificationCodeService{
		txRepo:               txRepo,
		verificationCodeRepo: verificationCodeRepo,
		smtpClient:           smtpClient,
	}
}
