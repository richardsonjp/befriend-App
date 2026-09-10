package app_resource

import (
	"context"
	"go-skeleton/internal/model"
	"go-skeleton/pkg/clients/db"
)

type AppResourceRepo interface {
	Create(ctx context.Context, m *model.AppResource) error
	Update(ctx context.Context, m model.AppResource, updatedFields ...string) (int64, error)
	GetBackendResource(ctx context.Context, method string, pathPattern string) (*model.AppResource, error)
	GetResourcesByRoleIDAndType(ctx context.Context, roleID string, resourceType string) ([]model.AppResource, error)
}

type appResourceRepo struct {
	dbdget db.DBGormDelegate
}

func NewAppResourceRepo(dbdget db.DBGormDelegate) AppResourceRepo {
	return &appResourceRepo{
		dbdget: dbdget,
	}
}
