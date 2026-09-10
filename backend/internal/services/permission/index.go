package permission

import (
	"context"
	"befriend/internal/model"
	repoPermission "befriend/internal/repositories/permission"
	"befriend/internal/repositories/tx"
)

type PermissionService interface {
	Create(ctx context.Context, payload CreatePayload) error
	GetAll(ctx context.Context) ([]model.Permission, error)
	GetByUserTypeAndRole(ctx context.Context, userType, roleID string) ([]repoPermission.PermissionWithAssignment, error)
}

type permissionService struct {
	txRepo         tx.TxRepo
	permissionRepo repoPermission.PermissionRepo
}

func NewPermissionService(txRepo tx.TxRepo,
	permissionRepo repoPermission.PermissionRepo) PermissionService {
	return &permissionService{
		txRepo:         txRepo,
		permissionRepo: permissionRepo,
	}
}
