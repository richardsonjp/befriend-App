package app_resource

import (
	"context"
	"befriend/internal/model"
)

func (s *appResourceService) GetBackendResource(ctx context.Context, method string, pathPattern string) (*model.AppResource, error) {
	return s.appResourceRepo.GetBackendResource(ctx, method, pathPattern)
}

func (s *appResourceService) GetFrontendPathByRoleID(ctx context.Context, roleID string) ([]string, error) {
	resources, err := s.appResourceRepo.GetResourcesByRoleIDAndType(ctx, roleID, "FRONTEND")
	if err != nil {
		return nil, err
	}

	var paths []string
	for _, r := range resources {
		paths = append(paths, r.PathPattern)
	}

	return paths, nil
}

func (s *appResourceService) GetBackendPathByRoleID(ctx context.Context, roleID string) ([]model.AppResource, error) {
	resources, err := s.appResourceRepo.GetResourcesByRoleIDAndType(ctx, roleID, "BACKEND")
	if err != nil {
		return nil, err
	}

	return resources, nil
}
