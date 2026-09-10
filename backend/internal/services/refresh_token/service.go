package refresh_token

import (
	"context"
	"befriend/internal/model"
)

func (s *refreshTokenService) Create(ctx context.Context, payload CreatePayload) error {
	data := s.setData(payload)
	err := s.refreshTokenRepo.Create(ctx, data)
	if err != nil {
		return err
	}

	return nil
}

func (s *refreshTokenService) setData(payload CreatePayload) *model.RefreshToken {
	return &model.RefreshToken{
		UserID:     payload.UserID,
		TokenHash:  payload.TokenHash,
		DeviceInfo: payload.DeviceInfo,
		IPAddress:  payload.IPAddress,
		ExpiresAt:  payload.ExpiresAt,
	}
}
