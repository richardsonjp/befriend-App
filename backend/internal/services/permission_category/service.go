package permission_category

import (
	"context"
	"befriend/internal/model"
	"befriend/internal/model/enum"
)

func (s *permissionCategoryService) Create(ctx context.Context, payload CreatePayload) error {
	data := s.setData(payload)
	err := s.permissionCategoryRepo.Create(ctx, data)
	if err != nil {
		return err
	}

	return nil
}

func (s *permissionCategoryService) GetAll(ctx context.Context) ([]model.PermissionCategory, error) {
	return s.permissionCategoryRepo.GetAll(ctx)
}

func (s *permissionCategoryService) GetByUserType(ctx context.Context, userType enum.UserType) ([]model.PermissionCategory, error) {
	return s.permissionCategoryRepo.GetByUserType(ctx, userType)
}

func (s *permissionCategoryService) setData(payload CreatePayload) *model.PermissionCategory {
	return &model.PermissionCategory{
		Name:           payload.Name,
		Description:    payload.Description,
		Icon:           payload.Icon,
		TargetUserType: enum.NewUserType(payload.TargetUserType),
		DisplayOrder:   payload.DisplayOrder,
	}
}
