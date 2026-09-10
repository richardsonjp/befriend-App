package pairing_code

import "time"

type CreatePayload struct {
	DeviceName string `json:"device_name" validate:"required,max=100"`
}

type ClaimPayload struct {
	Code       string `json:"code" validate:"required,max=16"`
	PollSecret string `json:"poll_secret" validate:"required,len=64,hexadecimal"`
}

type CreateResponse struct {
	Code       string    `json:"code"`        // shown in the QR as befriend://pair?code=…
	PollSecret string    `json:"poll_secret"` // stays on the Mac
	ExpiresAt  time.Time `json:"expires_at"`
}

type PendingResponse struct {
	DeviceName string    `json:"device_name"`
	ExpiresAt  time.Time `json:"expires_at"`
}
