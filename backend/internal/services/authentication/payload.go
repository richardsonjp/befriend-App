package authentication

import "befriend/internal/services/device"

// Login contains credentials for user authentication plus the device being signed in
type Login struct {
	Email    string               `json:"email" validate:"required,email,max=255"`
	Password string               `json:"password" validate:"required,max=72"`
	Device   device.CreatePayload `json:"device"`
}

// AppleLogin is a Sign in with Apple result from the app. The app generates a random nonce, sends its
// SHA-256 to Apple and the raw value here, so a token captured from another sign-in can't be replayed.
type AppleLogin struct {
	IdentityToken     string               `json:"identity_token" validate:"required,max=4096"`
	AuthorizationCode string               `json:"authorization_code" validate:"omitempty,max=1024"`
	Nonce             string               `json:"nonce" validate:"required,min=16,max=256"`
	Device            device.CreatePayload `json:"device"`
}

// GoogleLogin is a Google Sign-In result from the app; the raw nonce is passed to Google and here.
type GoogleLogin struct {
	IDToken string               `json:"id_token" validate:"required,max=4096"`
	Nonce   string               `json:"nonce" validate:"required,min=16,max=256"`
	Device  device.CreatePayload `json:"device"`
}

type RefreshPayload struct {
	RefreshToken string `json:"refresh_token" validate:"required,max=1024"`
}

type LogoutPayload struct {
	UserID   string
	DeviceID string
}
