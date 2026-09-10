package routes

import (
	"befriend/cmd/apiserver/app/store"
	"befriend/config"
	"befriend/internal/middlewares"

	"github.com/gofiber/fiber/v2"
	"github.com/gofiber/fiber/v2/middleware/logger"
)

func Ping(c *fiber.Ctx) error {
	return c.JSON(fiber.Map{"message": "pong"})
}

func NewHTTPServer(appStore *store.Store) *fiber.App {
	app := fiber.New(fiber.Config{
		AppName:               config.Config.System.AppName,
		DisableStartupMessage: true,
		EnablePrintRoutes:     true,
		// Header carrying the real client IP behind a proxy (e.g. CF-Connecting-IP via Cloudflare Tunnel).
		// It is honoured only for requests arriving from TrustedProxies; otherwise c.IP() is the socket
		// address, so clients can't forge their IP to dodge rate limits.
		ProxyHeader:             config.Config.System.ProxyHeader,
		EnableTrustedProxyCheck: true,
		TrustedProxies:          config.Config.System.TrustedProxies,
	})

	// Global Middlewares
	app.Use(logger.New(logger.Config{
		Format: "[Fiber] ${time} | ${status} | ${latency} | ${ip} | ${method} | ${path} ${error}\n",
		// Time format matching Gin (YYYY/MM/DD - HH:MM:SS)
		TimeFormat: "2006/01/02 - 15:04:05",
		TimeZone:   "Local",
	}))

	app.Use(middlewares.Recovery())

	app.Use(middlewares.Cors())

	app.Get("/ping", Ping)

	// Everything below requires the static API key; protected routes add PASETO auth per route.
	app.Use(middlewares.CheckHeaderStaticApiKey())

	// all system use api prefix /api
	api := app.Group("/api")

	// ======= AUTH ROUTE =======
	initAuthenticationRoute(api.Group("/auth"), appStore)

	// ======= APP ROUTE (signed in) =======
	initAppRoute(api, appStore)

	return app
}
