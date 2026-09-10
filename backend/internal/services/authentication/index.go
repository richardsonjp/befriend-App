package authentication

import (
	"context"
	"befriend/internal/repositories/tx"
	"befriend/internal/services/account"
	"befriend/internal/services/account_member"
	"befriend/internal/services/app_resource"
	"befriend/internal/services/operator"
	"befriend/internal/services/role"
	"befriend/internal/services/user"
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
