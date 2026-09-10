package user_auth

import (
	"go-skeleton/internal/services/authentication"
)

type UserAuthHandler struct {
	authenticationService authentication.AuthenticationService
}

func NewUserAuthHandler(authenticationService authentication.AuthenticationService) *UserAuthHandler {
	return &UserAuthHandler{
		authenticationService: authenticationService,
	}
}
