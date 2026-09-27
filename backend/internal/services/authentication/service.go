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
	// EMAIL_VERIFICATION_OFF: accounts registered before it was switched off may still be unverified; let them in.
	// if user.Status == enum.UNVERIFIED {
	// 	return nil, errors.From("UNAUTHORIZED").WithDetail("Email not verified")
	// }
	if user.Status != enum.ACTIVE && user.Status != enum.UNVERIFIED {
		return nil, errors.From("UNAUTHORIZED").WithDetail("Account is not active")
	}

	var response *AuthenticateSessionResponse
	err = s.txRepo.Run(ctx, func(ctx context.Context) error {
		params.Device.UserID = user.ID
		newDevice, err := s.deviceService.Create(ctx, params.Device)
		if err != nil {
			return err
		}
		response, err = s.issueSession(ctx, user.ID, newDevice.ID)
		return err
	})
	if err != nil {
		return nil, err
	}

	return response, nil
}

// RefreshSession rotates a refresh token: the presented token is marked rotated and a new pair is issued
// for the same device. Reusing a token long after it was rotated signs the whole device out.
func (s *authenticationService) RefreshSession(ctx context.Context, payload RefreshPayload) (*AuthenticateSessionResponse, error) {
	invalid := errors.From("UNAUTHORIZED").WithDetail("Invalid or expired refresh token")

	claims, err := paseto.ValidateToken(payload.RefreshToken, config.Config.PASETO.RefreshSecret)
	if err != nil {
		return nil, invalid
	}

	user, err := s.userService.GetUserByID(ctx, claims.UserID)
	if err != nil {
		if errors.Is(err, "DATA_NOT_FOUND") {
			return nil, invalid
		}
		return nil, err
	}
	// EMAIL_VERIFICATION_OFF: older unverified accounts may log in, so their sessions must refresh too.
	if user.Status != enum.ACTIVE && user.Status != enum.UNVERIFIED {
		return nil, errors.From("UNAUTHORIZED").WithDetail("Account is not active")
	}

	var response *AuthenticateSessionResponse
	reuseDetected := false
	err = s.txRepo.Run(ctx, func(ctx context.Context) error {
		current, err := s.refreshTokenService.GetForRotation(ctx, paseto.HashToken(payload.RefreshToken))
		if err != nil {
			if errors.Is(err, "DATA_NOT_FOUND") {
				return invalid
			}
			return err
		}
		if current.UserID != claims.UserID || current.DeviceID != claims.DeviceID {
			return invalid
		}

		grace := time.Duration(config.Config.PASETO.RefreshReuseGraceSec) * time.Second
		switch refresh_token.Decide(current, time.Now(), grace) {
		case refresh_token.DecisionReject:
			return invalid
		case refresh_token.DecisionReuseDetected:
			// Let the revocation commit (returning an error would roll it back); refuse after the transaction.
			reuseDetected = true
			return s.refreshTokenService.RevokeByDevice(ctx, current.DeviceID)
		}

		if err := s.refreshTokenService.MarkRotated(ctx, current.ID); err != nil {
			return err
		}
		response, err = s.issueSession(ctx, current.UserID, current.DeviceID)
		return err
	})
	if err != nil {
		return nil, err
	}
	if reuseDetected {
		return nil, invalid
	}

	return response, nil
}

// AuthenticateLogout revokes the device's refresh tokens; its short-lived access token expires on its own
func (s *authenticationService) AuthenticateLogout(ctx context.Context, payload LogoutPayload) error {
	return s.refreshTokenService.RevokeByDevice(ctx, payload.DeviceID)
}

// issueSession generates a token pair for one device and stores only the refresh token's hash.
// Call it inside a transaction.
func (s *authenticationService) issueSession(ctx context.Context, userID, deviceID string) (*AuthenticateSessionResponse, error) {
	accessToken, refreshToken, err := paseto.GenerateTokens(paseto.Claims{
		UserID:   userID,
		DeviceID: deviceID,
	})
	if err != nil {
		return nil, err
	}

	err = s.refreshTokenService.Create(ctx, refresh_token.CreatePayload{
		UserID:    userID,
		DeviceID:  deviceID,
		TokenHash: paseto.HashToken(refreshToken),
		ExpiresAt: time.Now().Add(time.Duration(config.Config.PASETO.RefreshExpiryDay) * 24 * time.Hour),
	})
	if err != nil {
		return nil, err
	}

	return &AuthenticateSessionResponse{
		AccessToken:  accessToken,
		RefreshToken: refreshToken,
		DeviceID:     deviceID,
	}, nil
}
