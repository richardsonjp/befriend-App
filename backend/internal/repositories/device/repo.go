package device

import (
	"context"

	"befriend/internal/model"
)

func (r *deviceRepo) Create(ctx context.Context, m *model.Device) (*model.Device, error) {
	if err := r.dbdget.Get(ctx).Create(m).Error; err != nil {
		return nil, err
	}
	return m, nil
}
