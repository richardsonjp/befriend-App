package question_set

import (
	"context"

	"befriend/internal/model"
	"befriend/pkg/utils/errors"

	"gorm.io/gorm"
)

func (r *questionSetRepo) GetActive(ctx context.Context) (*model.QuestionSet, error) {
	return r.take(ctx, "is_active")
}

func (r *questionSetRepo) GetByID(ctx context.Context, id string) (*model.QuestionSet, error) {
	return r.take(ctx, "id = ?", id)
}

func (r *questionSetRepo) take(ctx context.Context, where string, args ...interface{}) (*model.QuestionSet, error) {
	m := &model.QuestionSet{}
	q := r.dbdget.Get(ctx).Where(where, args...).Take(m)
	if q.Error != nil {
		if q.Error == gorm.ErrRecordNotFound {
			return nil, errors.From("DATA_NOT_FOUND")
		}
		return nil, q.Error
	}
	return m, nil
}
