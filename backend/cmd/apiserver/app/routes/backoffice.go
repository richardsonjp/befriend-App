package routes

import (
	"befriend/cmd/apiserver/app/store"

	"github.com/gofiber/fiber/v2"
)

func initBackofficeRoute(group fiber.Router, appStore *store.Store) {
	// role path
	group.Route("/role", func(router fiber.Router) {
		router.Get("/rbac-menu", appStore.RoleHandler.GetAvailablePermissions)
		router.Get("/:id", appStore.RoleHandler.GetRoleDetails)
	})
}
