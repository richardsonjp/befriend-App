package role_permission

import (
	"context"
	"go-skeleton/internal/model"
	"go-skeleton/internal/model/enum"
	"go-skeleton/internal/repositories/role_permission"
	"go-skeleton/internal/repositories/tx"
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
