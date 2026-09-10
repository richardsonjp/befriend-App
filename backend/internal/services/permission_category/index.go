package permission_category

import (
	"context"
	"befriend/internal/model"
	"befriend/internal/model/enum"
	"befriend/internal/repositories/permission_category"
	"befriend/internal/repositories/tx"
)

type PermissionCategoryService interface {
	Create(ctx context.Context, payload CreatePayload) error
	GetAll(ctx context.Context) ([]model.PermissionCategory, error)
	GetByUserType(ctx context.Context, userType enum.UserType) ([]model.PermissionCategory, error)
}

type permissionCategoryService struct {
	txRepo                 tx.TxRepo
	permissionCategoryRepo permission_category.PermissionCategoryRepo
}

func NewPermissionCategoryService(txRepo tx.TxRepo,
	permissionCategoryRepo permission_category.PermissionCategoryRepo) PermissionCategoryService {
	return &permissionCategoryService{
		txRepo:                 txRepo,
		permissionCategoryRepo: permissionCategoryRepo,
	}
}
