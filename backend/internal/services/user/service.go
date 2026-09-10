package user

import (
	"context"
	"strings"
	"time"

	"befriend/internal/model"
	"befriend/internal/model/enum"

	"golang.org/x/crypto/bcrypt"
)

func (s *userService) CreateUser(ctx context.Context, payload CreatePayload) (*model.User, error) {
	hashedPassword, err := bcrypt.GenerateFromPassword([]byte(payload.Password), bcrypt.DefaultCost)
	if err != nil {
		return nil, err
	}

	email := strings.ToLower(strings.TrimSpace(payload.Email))
	passwordHash := string(hashedPassword)
	return s.userRepo.Create(ctx, &model.User{
		Email:        &email,
		PasswordHash: &passwordHash,
		Status:       enum.UNVERIFIED,
	})
}

func (s *userService) GetUserByID(ctx context.Context, id string) (*model.User, error) {
	return s.userRepo.GetByID(ctx, id)
}

func (s *userService) GetUserByEmail(ctx context.Context, email string) (*model.User, error) {
	return s.userRepo.GetByEmail(ctx, email)
}

// MarkEmailVerified activates the account.
func (s *userService) MarkEmailVerified(ctx context.Context, id string) error {
	now := time.Now()
	_, err := s.userRepo.Update(ctx, model.User{
		ID:              id,
		Status:          enum.ACTIVE,
		EmailVerifiedAt: &now,
	}, "status", "email_verified_at")
	return err
}
