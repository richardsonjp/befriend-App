package routes

import (
	"befriend/cmd/apiserver/app/store"
	"befriend/config"
	"befriend/internal/middlewares"

	"github.com/gofiber/fiber/v2"
)

// pairingClaimPerMinute leaves room for a Mac polling every 2 seconds.
const pairingClaimPerMinute = 40

func initAuthenticationRoute(group fiber.Router, appStore *store.Store) {
	auth := appStore.MiddlewarePasetoAuth.MiddlewarePasetoAuth
	// Brute-force protection for passwords, codes and tokens: per client IP, per route.
	limit := middlewares.RateLimit(config.Config.RateLimit.AuthPerMinute)

	// public
	group.Post("/register", limit, appStore.UserHandler.Registration)
	group.Post("/verify-email", limit, appStore.UserHandler.VerifyEmail)
	group.Post("/resend-code", limit, appStore.UserHandler.ResendCode)
	group.Post("/login", limit, appStore.UserAuthHandler.Login)
	group.Post("/apple", limit, appStore.UserAuthHandler.LoginApple)
	group.Post("/google", limit, appStore.UserAuthHandler.LoginGoogle)
	group.Post("/refresh", limit, appStore.UserAuthHandler.Refresh)
	group.Post("/pairing", limit, appStore.PairingHandler.Create)
	group.Post("/pairing/claim", middlewares.RateLimit(pairingClaimPerMinute), appStore.PairingHandler.Claim)

	// protected
	group.Post("/logout", auth, appStore.UserAuthHandler.Logout)
}
