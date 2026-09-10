package device

import (
	"context"

	"befriend/internal/model"
	"befriend/pkg/clients/db"
)

type DeviceRepo interface {
	Create(ctx context.Context, m *model.Device) (*model.Device, error)
}

type deviceRepo struct {
	dbdget db.DBGormDelegate
}

func NewDeviceRepo(dbdget db.DBGormDelegate) DeviceRepo {
	return &deviceRepo{
		dbdget: dbdget,
	}
}
