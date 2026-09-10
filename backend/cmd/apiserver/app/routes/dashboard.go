package routes

import (
	"go-skeleton/cmd/apiserver/app/store"

	"github.com/gofiber/fiber/v2"
)

func initDashboardRoute(group fiber.Router, appStore *store.Store) {
	// role path
	group.Route("/role", func(router fiber.Router) {
		router.Get("/rbac-menu", appStore.RoleHandler.GetAvailablePermissions)
		router.Get("/:id", appStore.RoleHandler.GetRoleDetails)
	})
}
