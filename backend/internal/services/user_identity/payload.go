package user_identity

import "befriend/internal/model/enum"

type CreatePayload struct {
	UserID            string
	Provider          enum.IdentityProvider
	Subject           string
	Email             string // empty when the provider sent none
	EmailVerified     bool
	AppleRefreshToken *string
	AppleClientID     *string // set together with AppleRefreshToken
}
