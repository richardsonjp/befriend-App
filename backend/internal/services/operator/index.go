package operator

import (
	"context"
	"befriend/internal/model"
	"befriend/internal/repositories/operator"
	"befriend/internal/repositories/tx"
)

type OperatorService interface {
	GetOperatorByEmail(ctx context.Context, email string) (*model.Operator, error)
}

type operatorService struct {
	txRepo       tx.TxRepo
	operatorRepo operator.OperatorRepo
}

func NewOperatorService(
	txRepo tx.TxRepo,
	operatorRepo operator.OperatorRepo,
) OperatorService {
	return &operatorService{
		txRepo:       txRepo,
		operatorRepo: operatorRepo,
	}
}
