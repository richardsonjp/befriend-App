package user_application

import (
	"context"

	"befriend/internal/repositories/tx"
	"befriend/internal/services/friend"
	"befriend/internal/services/user"
	"befriend/internal/services/verification_code"
)

type UserApplicationService interface {
	Register(ctx context.Context, payload RegisterPayload) error
	VerifyUserEmail(ctx context.Context, payload VerifyEmailPayload) error
	ResendVerificationCode(ctx context.Context, payload ResendCodePayload) error
	GetMe(ctx context.Context, userID string) (*MeResponse, error)
}

type userApplicationService struct {
	txRepo                  tx.TxRepo
	userService             user.UserService
	verificationCodeService verification_code.VerificationCodeService
	friendService           friend.FriendService
}

func NewUserApplicationService(
	txRepo tx.TxRepo,
	userService user.UserService,
	verificationCodeService verification_code.VerificationCodeService,
	friendService friend.FriendService,
) UserApplicationService {
	return &userApplicationService{
		txRepo:                  txRepo,
		userService:             userService,
		verificationCodeService: verificationCodeService,
		friendService:           friendService,
	}
}
