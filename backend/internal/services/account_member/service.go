package account_member

import (
	"context"
	"befriend/internal/model"
	"time"
)

func (s *accountMemberService) CreateAccountMember(ctx context.Context, payload CreatePayload) (*model.AccountMember, error) {
	data := s.setData(payload)
	err := s.accountMemberRepo.Create(ctx, data)
	if err != nil {
		return nil, err
	}

	return data, nil
}

func (s *accountMemberService) GetAccountMemberByUserID(ctx context.Context, userID string) (*model.AccountMember, error) {
	data, err := s.accountMemberRepo.GetByUserID(ctx, userID)
	if err != nil {
		return nil, err
	}

	return data, nil
}

func (s *accountMemberService) setData(payload CreatePayload) *model.AccountMember {
	return &model.AccountMember{
		AccountID: payload.AccountID,
		UserID:    payload.UserID,
		RoleID:    payload.RoleID,
		JoinedAt:  time.Now(),
	}
}
