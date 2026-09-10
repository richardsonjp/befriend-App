package routes

import (
	"befriend/cmd/apiserver/app/store"
	"befriend/config"
	"befriend/internal/middlewares"

	"github.com/gofiber/fiber/v2"
	"github.com/gofiber/fiber/v2/middleware/logger" // Add this import
	//fiberSwagger "github.com/gofiber/swagger"
	//_ "befriend/docs"
)

func Ping(c *fiber.Ctx) error {
	return c.JSON(fiber.Map{"message": "pong"})
}

func NewHTTPServer(appStore *store.Store) *fiber.App {
	app := fiber.New(fiber.Config{
		AppName:               config.Config.System.AppName,
		DisableStartupMessage: true,
		EnablePrintRoutes:     true,
	})

	// Swagger
	//app.Get("/swagger/*", fiberSwagger.WrapHandler)

	// Global Middlewares

	// app.Use(middlewares.AccessLog())
	app.Use(logger.New(logger.Config{
		Format: "[Fiber] ${time} | ${status} | ${latency} | ${ip} | ${method} | ${path} ${error}\n",
		// Time format matching Gin (YYYY/MM/DD - HH:MM:SS)
		TimeFormat: "2006/01/02 - 15:04:05",
		TimeZone:   "Local",
	}))

	app.Use(middlewares.Recovery())

	app.Use(middlewares.Cors())

	app.Get("/ping", Ping)

	// Protected routes after static API key
	app.Use(middlewares.CheckHeaderStaticApiKey())

	// all system use api prefix /api
	api := app.Group("/api")

	// ======= AUTH ROUTE =======
	authGroup := api.Group("/auth")
	initAuthenticationRoute(authGroup, appStore)

	// ======= PASETO AUTH =======
	api.Use(appStore.MiddlewarePasetoAuth.MiddlewarePasetoAuth)
	api.Use(appStore.MiddlewareAccessControl.CheckAccess)

	// ======= DASHBOARD ROUTE =======
	dashboardGroup := api.Group("/dashboard")
	initDashboardRoute(dashboardGroup, appStore)

	// ======= BACKOFFICE ROUTE =======
	// backofficeGroup := api.Group("/backoffice")
	// initDashboardRoute(dashboardGroup, appStore)

	return app
}
