package role

import (
	"go-skeleton/internal/services/role"
)

type RoleHandler struct {
	roleService role.RoleService
}

func NewRoleHandler(roleService role.RoleService) *RoleHandler {
	return &RoleHandler{
		roleService: roleService,
	}
}
