package middlewares

import (
	"encoding/json"
	"go-skeleton/config"
	"go-skeleton/pkg/utils/logs"
	stringer "go-skeleton/pkg/utils/strings"
	"time"

	"github.com/gofiber/fiber/v2"
)

func AccessLog() fiber.Handler {
	return func(c *fiber.Ctx) error {
		t := time.Now()

		// Parse request body
		var reqBody map[string]interface{}
		if len(c.Body()) > 0 {
			_ = json.Unmarshal(c.Body(), &reqBody)
		}

		err := c.Next()

		end := time.Now()
		latency := end.Sub(t)

		// Get headers
		headers := c.GetReqHeaders()

		// --- FIX STARTS HERE ---
		// Check length before accessing [0]
		if val := headers["Client-Id"]; len(val) > 0 && val[0] != "" {
			headers["Client-Id"] = []string{stringer.MaskUUIDV4(val[0])}
		}
		if val := headers["Client-Secret"]; len(val) > 0 && val[0] != "" {
			headers["Client-Secret"] = []string{stringer.MaskUUIDV4(val[0])}
		}
		if val := headers["Authorization"]; len(val) > 0 && val[0] != "" {
			headers["Authorization"] = []string{stringer.MaskUUIDV4(val[0])}
		}
		// --- FIX ENDS HERE ---

		var clientIP string
		ips := c.IPs()

		if len(ips) > 0 {
			clientIP = ips[0]
		} else {
			clientIP = c.IP()
		}

		fields := logs.Fields{
			"client_ip":       clientIP,
			"client_os":       c.Get("Client-OS"),
			"client_version":  c.Get("Client-Version"),
			"request_id":      c.GetRespHeader("X-Request-Id"),
			"request_uri":     c.OriginalURL(),
			"method":          c.Method(),
			"handler":         c.Route().Path,
			"user_agent":      c.Get("User-Agent"),
			"referer":         c.Get("Referer"),
			"mode":            config.Config.System.Mode,
			"host":            c.Hostname(),
			"path":            c.Path(),
			"params":          string(c.Request().URI().QueryString()),
			"lang":            c.Get("Accept-Language"),
			"status":          c.Response().StatusCode(),
			"process_time":    latency.String(),
			"process_time_ns": latency.Nanoseconds(),
			"request_body":    reqBody,
			"request_header":  headers,
			"type_str":        "FIBER",
		}

		fields["route_path_params"] = c.AllParams()

		if err != nil {
			fields["error_string"] = err.Error()
			logs.Error("FIBER access log error", fields)
			return err
		}

		if c.Method() == "GET" || c.Method() == "OPTIONS" {
			return nil
		}

		logs.Info("FIBER access log", fields)
		logs.Activity(fields)

		return nil
	}
}
