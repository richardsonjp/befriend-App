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

// CreateProviderUser creates an active, password-less account for an Apple/Google identity.
// email is nil when the provider hasn't verified one.
func (s *userService) CreateProviderUser(ctx context.Context, email *string) (*model.User, error) {
	m := &model.User{Status: enum.ACTIVE}
	if email != nil {
		now := time.Now()
		normalized := strings.ToLower(strings.TrimSpace(*email))
		m.Email = &normalized
		m.EmailVerifiedAt = &now
	}
	return s.userRepo.Create(ctx, m)
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

// ClaimForProvider hands an unverified password account to the Apple/Google identity that just proved
// ownership of its email: the never-verified password is removed and the account activated. This stops
// someone pre-registering a victim's email to hold or hijack the account.
func (s *userService) ClaimForProvider(ctx context.Context, id string) error {
	now := time.Now()
	_, err := s.userRepo.Update(ctx, model.User{
		ID:              id,
		PasswordHash:    nil,
		Status:          enum.ACTIVE,
		EmailVerifiedAt: &now,
	}, "password_hash", "status", "email_verified_at")
	return err
}

func (s *userService) DeleteUser(ctx context.Context, id string) error {
	return s.userRepo.Delete(ctx, id)
}
