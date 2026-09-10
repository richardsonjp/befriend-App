package user

import (
	"context"

	"befriend/internal/model"
	"befriend/internal/repositories/tx"
	"befriend/internal/repositories/user"
)

type UserService interface {
	CreateUser(ctx context.Context, payload CreatePayload) (*model.User, error)
	GetUserByID(ctx context.Context, id string) (*model.User, error)
	GetUserByEmail(ctx context.Context, email string) (*model.User, error)
	UpdateEmailVerified(ctx context.Context, email string) (*model.User, error)
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
