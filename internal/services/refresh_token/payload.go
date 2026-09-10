package refresh_token

import "time"

type CreatePayload struct {
	UserID     string
	TokenHash  string
	DeviceInfo string
	IPAddress  string
	ExpiresAt  time.Time
}
