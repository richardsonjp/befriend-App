package app_resource

import (
	"context"
	"go-skeleton/internal/model"
	"go-skeleton/internal/repositories/app_resource"
	"go-skeleton/internal/repositories/tx"
)

type AppResourceService interface {
	GetBackendResource(ctx context.Context, method string, pathPattern string) (*model.AppResource, error)
	GetFrontendPathByRoleID(ctx context.Context, roleID string) ([]string, error)
	GetBackendPathByRoleID(ctx context.Context, roleID string) ([]model.AppResource, error)
}

type appResourceService struct {
	txRepo          tx.TxRepo
	appResourceRepo app_resource.AppResourceRepo
}

func NewAppResourceService(
	txRepo tx.TxRepo,
	appResourceRepo app_resource.AppResourceRepo,
) AppResourceService {
	return &appResourceService{
		txRepo:          txRepo,
		appResourceRepo: appResourceRepo,
	}
}
