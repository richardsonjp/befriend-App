package question_set

import (
	"context"

	"befriend/internal/model"
	repoQuestionSet "befriend/internal/repositories/question_set"
	"befriend/internal/repositories/tx"
)

type QuestionSetService interface {
	GetActive(ctx context.Context) (*model.QuestionSet, error)
}

type questionSetService struct {
	txRepo          tx.TxRepo
	questionSetRepo repoQuestionSet.QuestionSetRepo
}

func NewQuestionSetService(txRepo tx.TxRepo,
	questionSetRepo repoQuestionSet.QuestionSetRepo) QuestionSetService {
	return &questionSetService{
		txRepo:          txRepo,
		questionSetRepo: questionSetRepo,
	}
}
