package role

import (
	"context"
	"go-skeleton/internal/model"
	"go-skeleton/internal/model/enum"
	"go-skeleton/internal/repositories/role"
	"go-skeleton/internal/repositories/tx"
	"go-skeleton/internal/services/account"
	"go-skeleton/internal/services/permission"
	"go-skeleton/internal/services/permission_category"
	"go-skeleton/internal/services/role_permission"
)

type RoleService interface {
	CreateRole(ctx context.Context, payload CreatePayload) (*model.Role, error)
	CreateSystemDefaultRoles(ctx context.Context, accountType enum.AccountType, accountID string) (*model.Role, error)
	GetSystemRole(ctx context.Context, accountID string) (*model.Role, error)
	GetRoleDetails(ctx context.Context, roleID string) (*RoleDetailResponse, error)
	GetAvailablePermissions(ctx context.Context) ([]AvailablePermissionResponse, error)
	GetAvailablePermissionsByUserTypeRoleID(ctx context.Context, userType enum.UserType, roleID string) ([]AvailablePermissionResponse, error)
}

type roleService struct {
	txRepo                    tx.TxRepo
	roleRepo                  role.RoleRepo
	accountService            account.AccountService
	rolePermissionService     role_permission.RolePermissionService
	permissionService         permission.PermissionService
	permissionCategoryService permission_category.PermissionCategoryService
}

func NewRoleService(txRepo tx.TxRepo,
	roleRepo role.RoleRepo,
	accountService account.AccountService,
	rolePermissionService role_permission.RolePermissionService,
	permissionService permission.PermissionService,
	permissionCategoryService permission_category.PermissionCategoryService) RoleService {
	return &roleService{
		txRepo:                    txRepo,
		roleRepo:                  roleRepo,
		accountService:            accountService,
		rolePermissionService:     rolePermissionService,
		permissionService:         permissionService,
		permissionCategoryService: permissionCategoryService,
	}
}
