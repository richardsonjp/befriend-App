package routes

import (
	"befriend/cmd/apiserver/app/store"

	"github.com/gofiber/fiber/v2"
)

func initAuthenticationRoute(group fiber.Router, appStore *store.Store) {
	auth := appStore.MiddlewarePasetoAuth.MiddlewarePasetoAuth

	// public
	group.Post("/register", appStore.UserHandler.Registration)
	group.Post("/verify-email", appStore.UserHandler.VerifyEmail)
	group.Post("/login", appStore.UserAuthHandler.Login)

	// protected
	group.Post("/logout", auth, appStore.UserAuthHandler.Logout)
}
