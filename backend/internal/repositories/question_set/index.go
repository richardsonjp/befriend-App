package question_set

import (
	"context"

	"befriend/internal/model"
	"befriend/pkg/clients/db"
)

type QuestionSetRepo interface {
	GetActive(ctx context.Context) (*model.QuestionSet, error)
}

type questionSetRepo struct {
	dbdget db.DBGormDelegate
}

func NewQuestionSetRepo(dbdget db.DBGormDelegate) QuestionSetRepo {
	return &questionSetRepo{
		dbdget: dbdget,
	}
}
