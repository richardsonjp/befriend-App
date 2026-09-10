package authentication

import (
	"context"
	"time"

	"befriend/config"
	"befriend/internal/model/enum"
	"befriend/internal/services/refresh_token"
	"befriend/pkg/utils/errors"
	"befriend/pkg/utils/paseto"

	"golang.org/x/crypto/bcrypt"
)

// AuthenticateUser checks email/password, registers the signing-in device and issues its tokens
func (s *authenticationService) AuthenticateUser(ctx context.Context, params Login) (*AuthenticateSessionResponse, error) {
	user, err := s.userService.GetUserByEmail(ctx, params.Email)
	if err != nil {
		if errors.Is(err, "DATA_NOT_FOUND") {
			return nil, errors.From("UNAUTHORIZED").WithDetail("Invalid credentials")
		}
		return nil, err
	}

	// Check the password before revealing account state (unverified/inactive). Unknown email and wrong
	// password share one message; response timing still differs (bcrypt is skipped for unknown emails),
	// which we accept because /register already reveals whether an email exists.
	// Apple/Google-only accounts have no password hash.
	if user.PasswordHash == nil || bcrypt.CompareHashAndPassword([]byte(*user.PasswordHash), []byte(params.Password)) != nil {
		return nil, errors.From("UNAUTHORIZED").WithDetail("Invalid credentials")
	}
	if user.Status == enum.UNVERIFIED {
		return nil, errors.From("UNAUTHORIZED").WithDetail("Email not verified")
	}
	if user.Status != enum.ACTIVE {
		return nil, errors.From("UNAUTHORIZED").WithDetail("Account is not active")
	}

	var response *AuthenticateSessionResponse
	err = s.txRepo.Run(ctx, func(ctx context.Context) error {
		params.Device.UserID = user.ID
		newDevice, err := s.deviceService.Create(ctx, params.Device)
		if err != nil {
			return err
		}

		accessToken, refreshToken, err := paseto.GenerateTokens(paseto.Claims{
			UserID:   user.ID,
			DeviceID: newDevice.ID,
		})
		if err != nil {
			return err
		}

		err = s.refreshTokenService.Create(ctx, refresh_token.CreatePayload{
			UserID:    user.ID,
			DeviceID:  newDevice.ID,
			TokenHash: paseto.HashToken(refreshToken),
			ExpiresAt: time.Now().Add(time.Duration(config.Config.PASETO.RefreshExpiryDay) * 24 * time.Hour),
		})
		if err != nil {
			return err
		}

		response = &AuthenticateSessionResponse{
			AccessToken:  accessToken,
			RefreshToken: refreshToken,
			DeviceID:     newDevice.ID,
		}
		return nil
	})
	if err != nil {
		return nil, err
	}

	return response, nil
}

// AuthenticateLogout revokes the device's refresh tokens; its short-lived access token expires on its own
func (s *authenticationService) AuthenticateLogout(ctx context.Context, payload LogoutPayload) error {
	return s.refreshTokenService.RevokeByDevice(ctx, payload.DeviceID)
}
