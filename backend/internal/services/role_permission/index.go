package role_permission

import (
	"context"
	"befriend/internal/model"
	"befriend/internal/model/enum"
	"befriend/internal/repositories/role_permission"
	"befriend/internal/repositories/tx"
)

type RolePermissionService interface {
	Delete(ctx context.Context, roleID string, permissionID string) error
	CopyFromTemplate(ctx context.Context, roleID string, accountType enum.AccountType) error
	GetMenu(ctx context.Context, roleID string) ([]model.Permission, error)
	HasPermission(ctx context.Context, roleID string, permissionID string) (bool, error)
}

type rolePermissionService struct {
	txRepo             tx.TxRepo
	rolePermissionRepo role_permission.RolePermissionRepo
}

func NewRolePermissionService(txRepo tx.TxRepo,
	rolePermissionRepo role_permission.RolePermissionRepo) RolePermissionService {
	return &rolePermissionService{
		txRepo:             txRepo,
		rolePermissionRepo: rolePermissionRepo,
	}
}
