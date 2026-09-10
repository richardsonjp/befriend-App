package authentication

import (
	"context"

	"befriend/internal/repositories/tx"
	"befriend/internal/services/device"
	"befriend/internal/services/refresh_token"
	"befriend/internal/services/user"
)

type AuthenticationService interface {
	AuthenticateUser(ctx context.Context, payload Login) (*AuthenticateSessionResponse, error)
	AuthenticateLogout(ctx context.Context, payload LogoutPayload) error
}

type authenticationService struct {
	txRepo              tx.TxRepo
	userService         user.UserService
	deviceService       device.DeviceService
	refreshTokenService refresh_token.RefreshTokenService
}

func NewAuthenticationService(
	txRepo tx.TxRepo,
	userService user.UserService,
	deviceService device.DeviceService,
	refreshTokenService refresh_token.RefreshTokenService,
) AuthenticationService {
	return &authenticationService{
		txRepo:              txRepo,
		userService:         userService,
		deviceService:       deviceService,
		refreshTokenService: refreshTokenService,
	}
}
