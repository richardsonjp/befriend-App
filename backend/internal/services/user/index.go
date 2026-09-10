package user

import (
	"context"

	"befriend/internal/model"
	"befriend/internal/repositories/tx"
	"befriend/internal/repositories/user"
)

type UserService interface {
	CreateUser(ctx context.Context, payload CreatePayload) (*model.User, error)
	CreateProviderUser(ctx context.Context, email *string) (*model.User, error)
	GetUserByID(ctx context.Context, id string) (*model.User, error)
	GetUserByEmail(ctx context.Context, email string) (*model.User, error)
	MarkEmailVerified(ctx context.Context, id string) error
	ClaimForProvider(ctx context.Context, id string) error
	DeleteUser(ctx context.Context, id string) error
}

type userService struct {
	txRepo   tx.TxRepo
	userRepo user.UserRepo
}

func NewUserService(txRepo tx.TxRepo,
	userRepo user.UserRepo) UserService {
	return &userService{
		txRepo:   txRepo,
		userRepo: userRepo,
	}
}
