package permission

import (
	"context"
	"befriend/internal/model"
	repoPermission "befriend/internal/repositories/permission"
)

func (s *permissionService) Create(ctx context.Context, payload CreatePayload) error {
	data := s.setData(payload)
	err := s.permissionRepo.Create(ctx, data)
	if err != nil {
		return err
	}

	return nil
}

func (s *permissionService) GetAll(ctx context.Context) ([]model.Permission, error) {
	return s.permissionRepo.GetAll(ctx)
}

func (s *permissionService) GetByUserTypeAndRole(ctx context.Context, userType, roleID string) ([]repoPermission.PermissionWithAssignment, error) {
	return s.permissionRepo.GetByUserTypeAndRole(ctx, userType, roleID)
}

func (s *permissionService) setData(payload CreatePayload) *model.Permission {
	return &model.Permission{
		CategoryID:  payload.CategoryID,
		Code:        payload.Code,
		Name:        payload.Name,
		Description: payload.Description,
	}
}
