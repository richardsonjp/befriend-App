package permission_category

import (
	"context"
	"befriend/internal/model"
	"befriend/internal/model/enum"
	"befriend/pkg/clients/db"
)

type PermissionCategoryRepo interface {
	Create(ctx context.Context, m *model.PermissionCategory) error
	Update(ctx context.Context, m model.PermissionCategory, updatedFields ...string) (int64, error)
	GetAll(ctx context.Context) ([]model.PermissionCategory, error)
	GetByUserType(ctx context.Context, userType enum.UserType) ([]model.PermissionCategory, error)
}

type permissionCategoryRepo struct {
	dbdget db.DBGormDelegate
}

func NewPermissionCategoryRepo(dbdget db.DBGormDelegate) PermissionCategoryRepo {
	return &permissionCategoryRepo{
		dbdget: dbdget,
	}
}
