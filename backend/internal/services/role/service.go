package role

import (
	"context"
	"fmt"
	"go-skeleton/internal/model"
	"go-skeleton/internal/model/enum"
	"go-skeleton/pkg/utils/errors"
)

func (s *roleService) CreateRole(ctx context.Context, payloadRole CreatePayload) (*model.Role, error) {
	data := s.setData(payloadRole)
	result, err := s.roleRepo.Create(ctx, data)
	if err != nil {
		return nil, err
	}

	return result, nil
}

// CreateSystemDefaultRoles create system default roles
func (s *roleService) CreateSystemDefaultRoles(ctx context.Context, accountType enum.AccountType, accountID string) (*model.Role, error) {
	var result *model.Role
	switch accountType {
	case enum.PERSONAL:
		data, err := s.CreateRole(ctx, CreatePayload{
			AccountID:    accountID,
			Name:         "member",
			IsSystemRole: true,
		})
		if err != nil {
			return nil, err
		}
		result = data
	case enum.CORPORATE:
		data, err := s.CreateRole(ctx, CreatePayload{
			AccountID:    accountID,
			Name:         "owner",
			IsSystemRole: true,
		})
		if err != nil {
			return nil, err
		}
		result = data
	default:
		return nil, errors.From("BAD_REQUEST").WithDetail("Invalid account type")
	}

	if err := s.rolePermissionService.CopyFromTemplate(ctx, result.ID, accountType); err != nil {
		return nil, errors.From("ROLE").WithDetail(fmt.Sprintf("failed to copy role permission: %v", err))
	}

	return result, nil
}

// GetSystemRole deprecated
func (s *roleService) GetSystemRole(ctx context.Context, accountID string) (*model.Role, error) {
	result, err := s.roleRepo.GetSystemRole(ctx, accountID)
	if err != nil {
		return nil, err
	}

	return result, nil
}

func (s *roleService) GetRoleDetails(ctx context.Context, roleID string) (*RoleDetailResponse, error) {
	roleData, err := s.roleRepo.GetByID(ctx, roleID)
	if err != nil {
		return nil, err
	}

	accountData, err := s.accountService.GetAccountByID(ctx, roleData.AccountID)
	if err != nil {
		fmt.Println(err)
		if !errors.Is(err, "DATA_NOT_FOUND") {
			return nil, err
		}
	}

	userType := enum.OPERATOR
	if accountData != nil {
		if accountData.Type == enum.PERSONAL {
			userType = enum.USER_PERSONAL
		} else if accountData.Type == enum.CORPORATE {
			userType = enum.USER_CORPORATE
		}
	}

	permissions, err := s.GetAvailablePermissionsByUserTypeRoleID(ctx, userType, roleID)
	if err != nil {
		return nil, err
	}

	return &RoleDetailResponse{
		ID:           roleData.ID,
		Name:         roleData.Name,
		Description:  roleData.Description,
		IsSystemRole: roleData.IsSystemRole,
		Permissions:  permissions,
	}, nil
}

func (s *roleService) GetAvailablePermissionsByUserTypeRoleID(ctx context.Context, userType enum.UserType, roleID string) ([]AvailablePermissionResponse, error) {
	// 1. Get permissions with assignment status directly from repo
	permissions, err := s.permissionService.GetByUserTypeAndRole(ctx, userType.String(), roleID)
	if err != nil {
		return nil, err
	}

	var response []AvailablePermissionResponse
	if len(permissions) == 0 {
		return response, nil
	}

	// 2. Group permissions by category (assuming sorted by category display order)
	var currentCatID string
	var currentGroup *AvailablePermissionResponse

	for _, p := range permissions {
		if p.CategoryID != currentCatID {
			if currentGroup != nil {
				response = append(response, *currentGroup)
			}
			currentCatID = p.CategoryID
			currentGroup = &AvailablePermissionResponse{
				CategoryID:   p.CategoryID,
				CategoryName: p.CategoryName,
				Permissions:  []AvailablePermissionItem{},
			}
		}
		currentGroup.Permissions = append(currentGroup.Permissions, AvailablePermissionItem{
			ID:         p.ID,
			Code:       p.Code,
			Name:       p.Name,
			IsAssigned: p.IsAssigned,
		})
	}
	// append last group
	if currentGroup != nil {
		response = append(response, *currentGroup)
	}

	return response, nil
}

func (s *roleService) GetAvailablePermissions(ctx context.Context) ([]AvailablePermissionResponse, error) {
	categories, err := s.permissionCategoryService.GetAll(ctx)
	if err != nil {
		return nil, err
	}

	permissions, err := s.permissionService.GetAll(ctx)
	if err != nil {
		return nil, err
	}

	// map permissions by category
	permMap := make(map[string][]AvailablePermissionItem)
	for _, p := range permissions {
		permMap[p.CategoryID] = append(permMap[p.CategoryID], AvailablePermissionItem{
			ID:   p.ID,
			Code: p.Code,
			Name: p.Name,
		})
	}

	var response []AvailablePermissionResponse
	for _, c := range categories {
		response = append(response, AvailablePermissionResponse{
			CategoryID:   c.ID,
			CategoryName: c.Name,
			Permissions:  permMap[c.ID],
		})
	}

	return response, nil
}

func (s *roleService) setData(payload CreatePayload) *model.Role {
	return &model.Role{
		AccountID:    payload.AccountID,
		Name:         payload.Name,
		Description:  payload.Description,
		IsSystemRole: payload.IsSystemRole,
	}
}
