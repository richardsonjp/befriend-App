package authentication

import (
	"context"
	"go-skeleton/internal/repositories/tx"
	"go-skeleton/internal/services/account"
	"go-skeleton/internal/services/account_member"
	"go-skeleton/internal/services/app_resource"
	"go-skeleton/internal/services/operator"
	"go-skeleton/internal/services/role"
	"go-skeleton/internal/services/user"
)

type AuthenticationService interface {
	AuthenticateUser(ctx context.Context, payload Login) (*AuthenticateSessionResponse, error)
	AuthenticateOperator(ctx context.Context, payload Login) (*AuthenticateSessionResponse, error)
	AuthenticateLogout(ctx context.Context, payload LogoutPayload) error
}

type authenticationService struct {
	txRepo               tx.TxRepo
	userService          user.UserService
	operatorService      operator.OperatorService
	roleService          role.RoleService
	accountService       account.AccountService
	accountMemberService account_member.AccountMemberService
	appResourceService   app_resource.AppResourceService
}

func NewAuthenticationService(
	txRepo tx.TxRepo,
	userService user.UserService,
	operatorService operator.OperatorService,
	roleService role.RoleService,
	accountService account.AccountService,
	accountMemberService account_member.AccountMemberService,
	appResourceService app_resource.AppResourceService,
) AuthenticationService {
	return &authenticationService{
		txRepo:               txRepo,
		userService:          userService,
		operatorService:      operatorService,
		roleService:          roleService,
		accountService:       accountService,
		accountMemberService: accountMemberService,
		appResourceService:   appResourceService,
	}
}
