package account

import (
	"context"
	"go-skeleton/internal/model"
	"go-skeleton/internal/repositories/account"
	"go-skeleton/internal/repositories/tx"
)

type AccountService interface {
	CreateAccount(ctx context.Context, payload CreatePayload) (*model.Account, error)
	GetAccountByID(ctx context.Context, ID string) (*model.Account, error)
}

type accountService struct {
	txRepo      tx.TxRepo
	accountRepo account.AccountRepo
}

func NewAccountService(txRepo tx.TxRepo,
	accountRepo account.AccountRepo) AccountService {
	return &accountService{
		txRepo:      txRepo,
		accountRepo: accountRepo,
	}
}
