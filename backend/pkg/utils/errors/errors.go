package errors

import (
	"errors"
	"log"

	"github.com/gofiber/fiber/v2"
)

func Respond(c *fiber.Ctx, err error) error {
	if err == nil {
		return nil
	}

	// If it's our AppError, return as JSON
	if appErr, ok := err.(*AppError); ok {
		return c.Status(appErr.Status).JSON(appErr)
	}

	// Fallback: any other unknown Go error. Log it server-side; never echo internal error text
	// (SQL, constraint names, hostnames) to clients.
	log.Printf("unhandled error on %s %s: %v", c.Method(), c.Path(), err)
	internal := From("INTERNAL_SERVER_ERROR")

	return c.Status(internal.Status).JSON(internal)
}

func Is(err error, code string) bool {
	var appErr *AppError

	if errors.As(err, &appErr) {
		return appErr.Code == code
	}

	return false
}
