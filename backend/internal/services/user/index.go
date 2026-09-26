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
	UpdateSyncSettings(ctx context.Context, m model.User) error
	UpdateSkin(ctx context.Context, id string, skinID *string) error
	// SetArtist lets the account submit skins, or stops it.
	SetArtist(ctx context.Context, id string, artist bool) error
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
