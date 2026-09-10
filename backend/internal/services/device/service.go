package device

import (
	"context"

	"befriend/internal/model"
	"befriend/internal/model/enum"
)

// ponytail: one device row per sign-in; reuse rows via a client-sent device_id if they pile up.
func (s *deviceService) Create(ctx context.Context, payload CreatePayload) (*model.Device, error) {
	return s.deviceRepo.Create(ctx, &model.Device{
		UserID:   payload.UserID,
		Platform: enum.NewDevicePlatform(payload.Platform),
		Name:     payload.Name,
	})
}
