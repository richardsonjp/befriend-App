package refresh_token

import (
	"context"
	"time"

	"befriend/internal/model"
)

func (s *refreshTokenService) Create(ctx context.Context, payload CreatePayload) error {
	return s.refreshTokenRepo.Create(ctx, &model.RefreshToken{
		UserID:    payload.UserID,
		DeviceID:  payload.DeviceID,
		TokenHash: payload.TokenHash,
		ExpiresAt: payload.ExpiresAt,
	})
}

func (s *refreshTokenService) RevokeByDevice(ctx context.Context, deviceID string) error {
	return s.refreshTokenRepo.RevokeByDevice(ctx, deviceID, time.Now())
}
