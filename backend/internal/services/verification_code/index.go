package verification_code

import (
	"befriend/internal/model"
	"befriend/internal/repositories/tx"
	"befriend/internal/repositories/verification_code"
	"befriend/pkg/clients/email"
	"context"
)

type VerificationCodeService interface {
	Create(ctx context.Context, payload CreatePayload) (*model.VerificationCode, error)
	SendVerificationEmail(ctx context.Context, emailAddress string, data *model.VerificationCode) error
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
