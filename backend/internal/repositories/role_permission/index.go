package role_permission

import (
	"context"
	"befriend/internal/model"
	"befriend/pkg/clients/db"
)

type RolePermissionRepo interface {
	Create(ctx context.Context, m *model.RolePermission) error
	Delete(ctx context.Context, roleID string, permissionID string) error
	CopyFromTemplate(ctx context.Context, roleID string, templateName string) error
	GetMenu(ctx context.Context, roleID string) ([]model.Permission, error)
	HasPermission(ctx context.Context, roleID string, permissionID string) (bool, error)
}

type rolePermissionRepo struct {
	dbdget db.DBGormDelegate
}

func NewRolePermissionRepo(dbdget db.DBGormDelegate) RolePermissionRepo {
	return &rolePermissionRepo{
		dbdget: dbdget,
	}
}
