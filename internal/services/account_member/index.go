package account_member

import (
	"context"
	"go-skeleton/internal/model"
	"go-skeleton/internal/repositories/account_member"
)

type AccountMemberService interface {
	CreateAccountMember(ctx context.Context, payload CreatePayload) (*model.AccountMember, error)
	GetAccountMemberByUserID(ctx context.Context, userID string) (*model.AccountMember, error)
}

type accountMemberService struct {
	accountMemberRepo account_member.AccountMemberRepo
}

func NewAccountMemberService(accountMemberRepo account_member.AccountMemberRepo) AccountMemberService {
	return &accountMemberService{
		accountMemberRepo: accountMemberRepo,
	}
}
