package role_permission

import (
	"context"
	"fmt"
	"go-skeleton/internal/model"
)

func (r *rolePermissionRepo) Create(ctx context.Context, m *model.RolePermission) error {
	if err := r.dbdget.Get(ctx).Create(m).Error; err != nil {
		return err
	}
	return nil
}

func (r *rolePermissionRepo) Delete(ctx context.Context, roleID string, permissionID string) error {
	if err := r.dbdget.Get(ctx).Where("role_id = ? AND permission_id = ?", roleID, permissionID).Delete(&model.RolePermission{}).Error; err != nil {
		return err
	}
	return nil
}

func (r *rolePermissionRepo) CopyFromTemplate(ctx context.Context, roleID string, templateName string) error {
	query := `
		INSERT INTO role_permission (role_id, permission_id)
		SELECT ?, rp.permission_id
		FROM role r
		JOIN role_permission rp ON r.id = rp.role_id
		WHERE r.name = ? AND r.is_system_role = TRUE
	`
	if err := r.dbdget.Get(ctx).Exec(query, roleID, templateName).Error; err != nil {
		return err
	}
	return nil
}

func (r *rolePermissionRepo) GetMenu(ctx context.Context, roleID string) ([]model.Permission, error) {
	var permissions []model.Permission

	// Start with the model you want to return (Permission), not the link table
	err := r.dbdget.Get(ctx).
		Model(&model.Permission{}).
		Joins("INNER JOIN role_permission ON role_permission.permission_id = permission.id").
		Where("role_permission.role_id = ?", roleID).
		Find(&permissions).Error

	if err != nil {
		// Wrap the error for better debugging context
		return nil, fmt.Errorf("failed to get menu for role %s: %w", roleID, err)
	}

	return permissions, nil
}

func (r *rolePermissionRepo) HasPermission(ctx context.Context, roleID string, permissionID string) (bool, error) {
	var count int64
	err := r.dbdget.Get(ctx).
		Model(&model.RolePermission{}).
		Where("role_id = ? AND permission_id = ?", roleID, permissionID).
		Count(&count).Error
	if err != nil {
		return false, err
	}
	return count > 0, nil
}
