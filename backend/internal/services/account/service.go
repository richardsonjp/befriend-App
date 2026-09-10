package account

import (
	"context"
	"befriend/internal/model"
	"befriend/internal/model/enum"
)

func (s *accountService) CreateAccount(ctx context.Context, payload CreatePayload) (*model.Account, error) {
	data := s.setData(payload)
	err := s.accountRepo.Create(ctx, data)
	if err != nil {
		return nil, err
	}

	return data, nil
}

func (s *accountService) GetAccountByID(ctx context.Context, ID string) (*model.Account, error) {
	return s.accountRepo.GetByID(ctx, ID)
}

func (s *accountService) setData(payload CreatePayload) *model.Account {
	return &model.Account{
		Type:     enum.NewAccountType(payload.Type),
		Name:     payload.Name,
		IsFrozen: false,
		KycLevel: 0,
	}
}
