package account

import (
	"context"
	"befriend/internal/model"
	"befriend/internal/repositories/account"
	"befriend/internal/repositories/tx"
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
