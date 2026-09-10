package device

import (
	"context"

	"befriend/internal/model"
	repoDevice "befriend/internal/repositories/device"
	"befriend/internal/repositories/tx"
)

type DeviceService interface {
	Create(ctx context.Context, payload CreatePayload) (*model.Device, error)
	UpdatePushTokens(ctx context.Context, payload PushTokensPayload) error
	ListPushTargets(ctx context.Context, userID string) ([]model.Device, error)
	// ClearPushToken forgets a token APNs rejected: la_push_token, la_push_to_start_token or widget_push_token.
	ClearPushToken(ctx context.Context, deviceID, column string) error
}

type deviceService struct {
	txRepo     tx.TxRepo
	deviceRepo repoDevice.DeviceRepo
}

func NewDeviceService(txRepo tx.TxRepo,
	deviceRepo repoDevice.DeviceRepo) DeviceService {
	return &deviceService{
		txRepo:     txRepo,
		deviceRepo: deviceRepo,
	}
}
