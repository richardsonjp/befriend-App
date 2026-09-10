package routes

import (
	"befriend/cmd/apiserver/app/store"

	"github.com/gofiber/fiber/v2"
)

// initAppRoute registers the signed-in app endpoints.
func initAppRoute(api fiber.Router, appStore *store.Store) {
	auth := appStore.MiddlewarePasetoAuth.MiddlewarePasetoAuth

	api.Get("/me", auth, appStore.UserHandler.GetMe)
	api.Delete("/me", auth, appStore.UserAuthHandler.DeleteAccount)
	api.Get("/onboarding/questions", auth, appStore.OnboardingHandler.GetQuestions)
	api.Post("/onboarding/complete", auth, appStore.OnboardingHandler.Complete)
	api.Get("/friend", auth, appStore.FriendHandler.GetFriend)
}
