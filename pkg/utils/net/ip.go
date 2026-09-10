package net

import (
	"strings"

	"github.com/gofiber/fiber/v2"
)

// GetClientIpAddressFiber gets client IP Address for Fiber
func GetClientIpAddressFiber(c *fiber.Ctx) string {
	for _, h := range []string{"X-Forwarded-For", "X-Real-Ip"} {
		for _, v := range strings.Split(c.Get(h), ",") {
			ip := strings.TrimSpace(v)
			if len(ip) > 0 {
				return ip
			}
		}
	}
	return c.IP()
}
