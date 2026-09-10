package authentication

import "befriend/internal/services/device"

// Login contains credentials for user authentication plus the device being signed in
type Login struct {
	Email    string               `json:"email" validate:"required,email,max=255"`
	Password string               `json:"password" validate:"required,max=72"`
	Device   device.CreatePayload `json:"device"`
}

type RefreshPayload struct {
	RefreshToken string `json:"refresh_token" validate:"required,max=1024"`
}

type LogoutPayload struct {
	UserID   string
	DeviceID string
}
