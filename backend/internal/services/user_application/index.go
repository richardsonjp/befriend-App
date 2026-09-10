package user_application

import (
	"context"
	"go-skeleton/internal/repositories/tx"
	"go-skeleton/internal/services/account"
	"go-skeleton/internal/services/account_member"
	"go-skeleton/internal/services/role"
	"go-skeleton/internal/services/user"
	"go-skeleton/internal/services/verification_code"
)

type UserApplicationService interface {
	Register(ctx context.Context, payload RegisterPayload) error
	VerifyUserEmail(ctx context.Context, payload VerifyEmailPayload) error
}

type userApplicationService struct {
	txRepo                  tx.TxRepo
	userService             user.UserService
	roleService             role.RoleService
	accountService          account.AccountService
	accountMemberService    account_member.AccountMemberService
	verificationCodeService verification_code.VerificationCodeService
}

func NewUserApplicationService(
	txRepo tx.TxRepo,
	userService user.UserService,
	roleService role.RoleService,
	accountService account.AccountService,
	accountMemberService account_member.AccountMemberService,
	verificationCodeService verification_code.VerificationCodeService,
) UserApplicationService {
	return &userApplicationService{
		txRepo:                  txRepo,
		userService:             userService,
		roleService:             roleService,
		accountService:          accountService,
		accountMemberService:    accountMemberService,
		verificationCodeService: verificationCodeService,
	}
}
