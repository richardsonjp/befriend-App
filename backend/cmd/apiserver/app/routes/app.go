package routes

import (
	"befriend/cmd/apiserver/app/store"
	"befriend/config"
	"befriend/internal/middlewares"

	"github.com/gofiber/fiber/v2"
)

// submissionsPerMinute caps skin uploads per client; each one is unzipped and built.
const submissionsPerMinute = 5

// purchasesPerMinute bounds purchase checks per client; restoring sends one per past purchase.
const purchasesPerMinute = 30

// initAppRoute registers the signed-in app endpoints.
func initAppRoute(api fiber.Router, appStore *store.Store) {
	auth := appStore.MiddlewarePasetoAuth.MiddlewarePasetoAuth
	// Pairing codes are short: limit guessing them even for signed-in users.
	codeLimit := middlewares.RateLimit(config.Config.RateLimit.AuthPerMinute)

	api.Get("/me", auth, appStore.UserHandler.GetMe)
	api.Delete("/me", auth, appStore.UserAuthHandler.DeleteAccount)
	api.Get("/me/settings", auth, appStore.UserHandler.GetSettings)
	api.Patch("/me/settings", auth, appStore.UserHandler.UpdateSettings)
	api.Put("/devices/me/push-tokens", auth, appStore.DeviceHandler.UpdatePushTokens)
	api.Get("/onboarding/questions", auth, appStore.OnboardingHandler.GetQuestions)
	api.Post("/onboarding/complete", auth, appStore.OnboardingHandler.Complete)
	api.Get("/friend", auth, appStore.FriendHandler.GetFriend)
	api.Get("/pairing/:code", codeLimit, auth, appStore.PairingHandler.Get)
	api.Post("/pairing/:code/confirm", codeLimit, auth, appStore.PairingHandler.Confirm)
	api.Post("/trigger-events", auth, appStore.TriggerEventHandler.Record)
	api.Delete("/trigger-events", auth, appStore.TriggerEventHandler.DeleteAll)
	api.Get("/presence", auth, appStore.PresenceHandler.Get)
	api.Post("/presence/claim", auth, appStore.PresenceHandler.Claim)
	api.Post("/presence/release", auth, appStore.PresenceHandler.Release)
	api.Get("/presence/ws", auth, appStore.PresenceHandler.RequireUpgrade, appStore.PresenceHandler.Socket())
	api.Get("/skins", auth, appStore.SkinHandler.List)
	api.Get("/skins/:id/archive", auth, appStore.SkinHandler.Archive)
	api.Get("/skins/submissions", auth, appStore.SkinHandler.Submissions)
	api.Get("/skins/catalog", auth, appStore.SkinHandler.Catalog)
	api.Post("/skins/purchases", middlewares.RateLimit(purchasesPerMinute), auth, appStore.SkinHandler.Purchase)
	api.Post("/skins/submissions", middlewares.RateLimit(submissionsPerMinute), auth, appStore.SkinHandler.Submit)
}
