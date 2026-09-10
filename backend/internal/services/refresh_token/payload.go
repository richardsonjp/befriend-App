package refresh_token

import "time"

type CreatePayload struct {
	UserID    string
	DeviceID  string
	TokenHash string
	ExpiresAt time.Time
}
