package permission_category

import (
	"context"
	"go-skeleton/internal/model"
	"go-skeleton/internal/model/enum"
)

func (r *permissionCategoryRepo) Create(ctx context.Context, m *model.PermissionCategory) error {
	if err := r.dbdget.Get(ctx).Create(m).Error; err != nil {
		return err
	}
	return nil
}

func (r *permissionCategoryRepo) Update(ctx context.Context, m model.PermissionCategory, updatedFields ...string) (int64, error) {
	query := r.dbdget.Get(ctx).
		Model(&m).
		Where("id = ?", m.ID)

	if len(updatedFields) > 0 {
		updatedFields = append(updatedFields, "updated_at")
		query = query.Select(updatedFields)
	}

	query.Updates(m)

	if query.Error != nil {
		return 0, query.Error
	}

	return query.RowsAffected, nil
}

func (r *permissionCategoryRepo) GetAll(ctx context.Context) ([]model.PermissionCategory, error) {
	var categories []model.PermissionCategory
	if err := r.dbdget.Get(ctx).Find(&categories).Error; err != nil {
		return nil, err
	}
	return categories, nil
}

func (r *permissionCategoryRepo) GetByUserType(ctx context.Context, userType enum.UserType) ([]model.PermissionCategory, error) {
	var categories []model.PermissionCategory
	if err := r.dbdget.Get(ctx).Where("target_user_type = ?", userType).Find(&categories).Error; err != nil {
		return nil, err
	}
	return categories, nil
}
