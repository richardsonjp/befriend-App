package middlewares

import (
	"fmt"
	"runtime/debug"

	"github.com/gofiber/fiber/v2"
)

func Recovery() fiber.Handler {
	return func(c *fiber.Ctx) error {
		defer func() {
			if r := recover(); r != nil {
				// 1. Get the error message
				err, ok := r.(error)
				if !ok {
					err = fmt.Errorf("%v", r)
				}

				// 2. Log the stack trace (optional, if you want full details)
				fmt.Println(string(debug.Stack()))

				// 3. IMPORTANT: Set the error back into Fiber's context
				// This allows the Logger middleware to see it and print ${error}
				// We create a new error to pass down
				c.Status(fiber.StatusInternalServerError)

				// You can return the error here so the Logger middleware picks it up
				// The logger middleware runs 'after' this function returns in the chain unwinding
				_ = c.JSON(fiber.Map{
					"message": "Internal Server Error",
					"debug":   err.Error(), // Remove this in production
				})
			}
		}()

		// Return the error from the next handler if it exists
		return c.Next()
	}
}
