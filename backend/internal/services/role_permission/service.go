package role_permission

import (
	"context"
	"befriend/internal/model"
	"befriend/internal/model/enum"
)

func (s *rolePermissionService) Create(ctx context.Context, payload CreatePayload) error {
	data := s.setData(payload)
	err := s.rolePermissionRepo.Create(ctx, data)
	if err != nil {
		return err
	}

	return nil
}

func (s *rolePermissionService) Delete(ctx context.Context, roleID string, permissionID string) error {
	return s.rolePermissionRepo.Delete(ctx, roleID, permissionID)
}

func (s *rolePermissionService) CopyFromTemplate(ctx context.Context, roleID string, accountType enum.AccountType) error {
	var templateRoles = map[enum.AccountType]string{
		enum.PERSONAL:  "Template: Member",
		enum.CORPORATE: "Template: Owner",
	}
	templateName := templateRoles[accountType]
	return s.rolePermissionRepo.CopyFromTemplate(ctx, roleID, templateName)
}

func (s *rolePermissionService) GetMenu(ctx context.Context, roleID string) ([]model.Permission, error) {
	return s.rolePermissionRepo.GetMenu(ctx, roleID)
}

func (s *rolePermissionService) HasPermission(ctx context.Context, roleID string, permissionID string) (bool, error) {
	return s.rolePermissionRepo.HasPermission(ctx, roleID, permissionID)
}

func (s *rolePermissionService) setData(payload CreatePayload) *model.RolePermission {
	return &model.RolePermission{
		RoleID:       payload.RoleID,
		PermissionID: payload.PermissionID,
	}
}
