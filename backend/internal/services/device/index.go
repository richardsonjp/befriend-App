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
