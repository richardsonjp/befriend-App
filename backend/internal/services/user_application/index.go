package user_application

import (
	"context"

	"befriend/internal/repositories/tx"
	"befriend/internal/services/user"
	"befriend/internal/services/verification_code"
)

type UserApplicationService interface {
	Register(ctx context.Context, payload RegisterPayload) error
	VerifyUserEmail(ctx context.Context, payload VerifyEmailPayload) error
}

type userApplicationService struct {
	txRepo                  tx.TxRepo
	userService             user.UserService
	verificationCodeService verification_code.VerificationCodeService
}

func NewUserApplicationService(
	txRepo tx.TxRepo,
	userService user.UserService,
	verificationCodeService verification_code.VerificationCodeService,
) UserApplicationService {
	return &userApplicationService{
		txRepo:                  txRepo,
		userService:             userService,
		verificationCodeService: verificationCodeService,
	}
}
