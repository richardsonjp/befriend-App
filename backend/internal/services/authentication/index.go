package authentication

import (
	"context"

	"befriend/internal/repositories/tx"
	"befriend/internal/services/device"
	"befriend/internal/services/refresh_token"
	"befriend/internal/services/user"
	"befriend/internal/services/user_identity"
	"befriend/pkg/clients/apple"
	"befriend/pkg/clients/idtoken"
)

type AuthenticationService interface {
	AuthenticateUser(ctx context.Context, payload Login) (*AuthenticateSessionResponse, error)
	AuthenticateWithApple(ctx context.Context, payload AppleLogin) (*AuthenticateSessionResponse, error)
	AuthenticateWithGoogle(ctx context.Context, payload GoogleLogin) (*AuthenticateSessionResponse, error)
	RefreshSession(ctx context.Context, payload RefreshPayload) (*AuthenticateSessionResponse, error)
	AuthenticateLogout(ctx context.Context, payload LogoutPayload) error
}

type authenticationService struct {
	txRepo              tx.TxRepo
	userService         user.UserService
	userIdentityService user_identity.UserIdentityService
	deviceService       device.DeviceService
	refreshTokenService refresh_token.RefreshTokenService
	appleVerifier       *idtoken.Verifier // nil when Sign in with Apple isn't configured
	googleVerifier      *idtoken.Verifier // nil when Google sign-in isn't configured
	appleClient         *apple.Client     // nil when Apple server credentials aren't configured
}

func NewAuthenticationService(
	txRepo tx.TxRepo,
	userService user.UserService,
	userIdentityService user_identity.UserIdentityService,
	deviceService device.DeviceService,
	refreshTokenService refresh_token.RefreshTokenService,
	appleVerifier *idtoken.Verifier,
	googleVerifier *idtoken.Verifier,
	appleClient *apple.Client,
) AuthenticationService {
	return &authenticationService{
		txRepo:              txRepo,
		userService:         userService,
		userIdentityService: userIdentityService,
		deviceService:       deviceService,
		refreshTokenService: refreshTokenService,
		appleVerifier:       appleVerifier,
		googleVerifier:      googleVerifier,
		appleClient:         appleClient,
	}
}
