package routes

import (
	"go-skeleton/cmd/apiserver/app/store"

	"github.com/gofiber/fiber/v2"
)

func initAuthenticationRoute(group fiber.Router, appStore *store.Store) {
	// public
	group.Route("/user", func(router fiber.Router) {
		group.Post("/register", appStore.UserHandler.Registration)
		group.Post("/verify-email", appStore.UserHandler.VerifyEmail)
		group.Post("/login", appStore.UserAuthHandler.Login)
		// protected
		protected := group.Use(appStore.MiddlewarePasetoAuth.MiddlewarePasetoAuth)
		protected.Post("/logout", appStore.UserAuthHandler.Logout)
	})

	group.Route("/backoffice", func(group fiber.Router) {
		group.Post("/login", appStore.UserAuthHandler.Login)
	})

}
