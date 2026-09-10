package middlewares

import (
	"fmt"
	"go-skeleton/internal/services/app_resource"
	"go-skeleton/internal/services/role_permission"
	"go-skeleton/pkg/utils/errors"
	"strings"

	"github.com/gofiber/fiber/v2"
)

type MiddlewareAccessControl struct {
	appResourceService    app_resource.AppResourceService
	rolePermissionService role_permission.RolePermissionService
}

func NewMiddlewareAccessControl(
	appResourceService app_resource.AppResourceService,
	rolePermissionService role_permission.RolePermissionService,
) MiddlewareAccessControl {
	return MiddlewareAccessControl{
		appResourceService:    appResourceService,
		rolePermissionService: rolePermissionService,
	}
}

func (m *MiddlewareAccessControl) CheckAccess(c *fiber.Ctx) error {
	roleID, ok := c.Locals("role_id").(string)
	if !ok || roleID == "" {
		return errors.Respond(c, errors.From("UNAUTHORIZED").WithDetail("Role not found in context"))
	}

	resources, err := m.appResourceService.GetBackendPathByRoleID(c.Context(), roleID)
	if err != nil {
		return errors.Respond(c, errors.From("FORBIDDEN").WithDetail(fmt.Sprintf("Role %s not found", roleID)))
	}

	method := c.Method()
	pathPattern := c.Path()
	for _, resource := range resources {
		if resource.Method == method && matchPath(resource.PathPattern, pathPattern) {
			return c.Next()
		}
	}

	return errors.Respond(c, errors.From("FORBIDDEN").WithDetail("You do not have permission to access this resource"))
}

func matchPath(pattern, path string) bool {
	if pattern == path {
		return true
	}

	patternParts := strings.Split(pattern, "/")
	pathParts := strings.Split(path, "/")

	// Clean up empty parts usually resulting from leading/trailing slashes
	if len(patternParts) > 0 && patternParts[0] == "" {
		patternParts = patternParts[1:]
	}
	if len(patternParts) > 0 && patternParts[len(patternParts)-1] == "" {
		patternParts = patternParts[:len(patternParts)-1]
	}
	if len(pathParts) > 0 && pathParts[0] == "" {
		pathParts = pathParts[1:]
	}
	if len(pathParts) > 0 && pathParts[len(pathParts)-1] == "" {
		pathParts = pathParts[:len(pathParts)-1]
	}

	if len(patternParts) != len(pathParts) {
		return false
	}

	for i, part := range patternParts {
		if strings.HasPrefix(part, ":") {
			continue
		}
		if part != pathParts[i] {
			return false
		}
	}
	return true
}
