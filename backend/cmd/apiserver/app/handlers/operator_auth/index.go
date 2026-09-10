package operator_auth

import (
	"go-skeleton/internal/services/authentication"
)

type OperatorAuthHandler struct {
	authenticationService authentication.AuthenticationService
}

func NewOperatorAuthHandler(authenticationService authentication.AuthenticationService) *OperatorAuthHandler {
	return &OperatorAuthHandler{
		authenticationService: authenticationService,
	}
}
