package device

import (
	"context"

	"befriend/internal/model"
	"befriend/pkg/clients/db"
)

type DeviceRepo interface {
	Create(ctx context.Context, m *model.Device) (*model.Device, error)
	UpdatePushTokens(ctx context.Context, id, userID string, fields map[string]interface{}) error
	// ListPushTargets returns the user's iPhones that uploaded APNs tokens.
	ListPushTargets(ctx context.Context, userID string) ([]model.Device, error)
	ClearColumns(ctx context.Context, id string, columns ...string) error
}

type deviceRepo struct {
	dbdget db.DBGormDelegate
}

func NewDeviceRepo(dbdget db.DBGormDelegate) DeviceRepo {
	return &deviceRepo{
		dbdget: dbdget,
	}
}
