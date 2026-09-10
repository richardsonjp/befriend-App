package personality_version

import (
	"context"

	"befriend/internal/model"
	"befriend/pkg/utils/errors"

	"gorm.io/gorm"
)

func (r *personalityVersionRepo) Create(ctx context.Context, m *model.PersonalityVersion) (*model.PersonalityVersion, error) {
	if err := r.dbdget.Get(ctx).Create(m).Error; err != nil {
		return nil, err
	}
	return m, nil
}

func (r *personalityVersionRepo) GetLatestByFriend(ctx context.Context, friendID string) (*model.PersonalityVersion, error) {
	m := &model.PersonalityVersion{}
	q := r.dbdget.Get(ctx).Where("friend_id = ?", friendID).Order("version DESC").Take(m)
	if q.Error != nil {
		if q.Error == gorm.ErrRecordNotFound {
			return nil, errors.From("DATA_NOT_FOUND")
		}
		return nil, q.Error
	}
	return m, nil
}
