package permission

import (
	"context"
	"befriend/internal/model"
)

func (r *permissionRepo) Create(ctx context.Context, m *model.Permission) error {
	if err := r.dbdget.Get(ctx).Create(m).Error; err != nil {
		return err
	}
	return nil
}

func (r *permissionRepo) Update(ctx context.Context, m model.Permission, updatedFields ...string) (int64, error) {
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

func (r *permissionRepo) GetAll(ctx context.Context) ([]model.Permission, error) {
	var permissions []model.Permission
	if err := r.dbdget.Get(ctx).Find(&permissions).Error; err != nil {
		return nil, err
	}
	return permissions, nil
}

func (r *permissionRepo) GetByUserTypeAndRole(ctx context.Context, userType, roleID string) ([]PermissionWithAssignment, error) {
	var results []PermissionWithAssignment

	err := r.dbdget.Get(ctx).
		Table("permission p").
		Select("p.id, p.code, p.name, pc.id as category_id, pc.name as category_name, (rp.permission_id IS NOT NULL) as is_assigned").
		Joins("JOIN permission_category pc ON p.category_id = pc.id").
		Joins("LEFT JOIN role_permission rp ON p.id = rp.permission_id AND rp.role_id = ?", roleID).
		Where("pc.target_user_type = ?", userType).
		Order("pc.display_order, p.code").
		Scan(&results).Error

	if err != nil {
		return nil, err
	}

	return results, nil
}
