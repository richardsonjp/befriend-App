package authentication

import "befriend/internal/services/device"

// Login contains credentials for user authentication plus the device being signed in
type Login struct {
	Email    string               `json:"email" validate:"required,email,max=255"`
	Password string               `json:"password" validate:"required,max=72"`
	Device   device.CreatePayload `json:"device"`
}

type LogoutPayload struct {
	UserID   string
	DeviceID string
}
