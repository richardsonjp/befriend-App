package question_set

import (
	"context"

	"befriend/internal/model"
)

func (s *questionSetService) GetActive(ctx context.Context) (*model.QuestionSet, error) {
	return s.questionSetRepo.GetActive(ctx)
}

func (s *questionSetService) GetByID(ctx context.Context, id string) (*model.QuestionSet, error) {
	return s.questionSetRepo.GetByID(ctx, id)
}
