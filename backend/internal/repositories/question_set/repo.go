package question_set

import (
	"context"

	"befriend/internal/model"
	"befriend/pkg/utils/errors"

	"gorm.io/gorm"
)

func (r *questionSetRepo) GetActive(ctx context.Context) (*model.QuestionSet, error) {
	m := &model.QuestionSet{}
	q := r.dbdget.Get(ctx).Where("is_active").Take(m)
	if q.Error != nil {
		if q.Error == gorm.ErrRecordNotFound {
			return nil, errors.From("DATA_NOT_FOUND")
		}
		return nil, q.Error
	}
	return m, nil
}
