package permission

import (
	"context"
	"go-skeleton/internal/model"
	"go-skeleton/pkg/clients/db"
)

type PermissionRepo interface {
	Create(ctx context.Context, m *model.Permission) error
	Update(ctx context.Context, m model.Permission, updatedFields ...string) (int64, error)
	GetAll(ctx context.Context) ([]model.Permission, error)
	GetByUserTypeAndRole(ctx context.Context, userType, roleID string) ([]PermissionWithAssignment, error)
}

type permissionRepo struct {
	dbdget db.DBGormDelegate
}

func NewPermissionRepo(dbdget db.DBGormDelegate) PermissionRepo {
	return &permissionRepo{
		dbdget: dbdget,
	}
}
