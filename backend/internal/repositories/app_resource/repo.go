package app_resource

import (
	"context"
	"befriend/internal/model"
)

func (r *appResourceRepo) Create(ctx context.Context, m *model.AppResource) error {
	if err := r.dbdget.Get(ctx).Create(m).Error; err != nil {
		return err
	}
	return nil
}

func (r *appResourceRepo) Update(ctx context.Context, m model.AppResource, updatedFields ...string) (int64, error) {
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

func (r *appResourceRepo) GetBackendResource(ctx context.Context, method string, pathPattern string) (*model.AppResource, error) {
	var resource model.AppResource
	err := r.dbdget.Get(ctx).
		Where("type = 'BACKEND' AND method = ? AND path_pattern = ?", method, pathPattern).
		First(&resource).Error
	if err != nil {
		return nil, err
	}
	return &resource, nil
}

func (r *appResourceRepo) GetResourcesByRoleIDAndType(ctx context.Context, roleID string, resourceType string) ([]model.AppResource, error) {
	var resources []model.AppResource
	err := r.dbdget.Get(ctx).
		Table("app_resource ar").
		Joins("JOIN permission p ON p.id = ar.required_permission_id").
		Joins("JOIN role_permission rp ON rp.permission_id = p.id").
		Where("rp.role_id = ? AND ar.type = ?", roleID, resourceType).
		Find(&resources).Error

	if err != nil {
		return nil, err
	}
	return resources, nil
}
