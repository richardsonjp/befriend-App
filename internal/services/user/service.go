package user

import (
	"context"
	"go-skeleton/internal/model"
	"go-skeleton/internal/model/enum"
	"time"

	"golang.org/x/crypto/bcrypt"
)

func (s *userService) CreateUser(ctx context.Context, payload CreatePayload) (*model.User, error) {
	hashedPassword, err := bcrypt.GenerateFromPassword([]byte(payload.Password), bcrypt.DefaultCost)
	if err != nil {
		return nil, err
	}
	payload.Password = string(hashedPassword)
	data := s.setData(payload)

	result, err := s.userRepo.Create(ctx, data)
	if err != nil {
		return nil, err
	}

	return result, nil
}

func (s *userService) GetUserByID(ctx context.Context, id uint) (*model.User, error) {
	return s.userRepo.GetByID(ctx, id)
}

func (s *userService) GetUserByEmail(ctx context.Context, email string) (*model.User, error) {
	return s.userRepo.GetByEmail(ctx, email)
}

func (s *userService) UpdateEmailVerified(ctx context.Context, email string) (*model.User, error) {
	data, err := s.GetUserByEmail(ctx, email)
	if err != nil {
		return nil, err
	}

	now := time.Now()
	data.Status = enum.ACTIVE
	data.EmailVerifiedAt = &now
	_, err = s.userRepo.Update(ctx, *data, "status", "email_verified_at")
	if err != nil {
		return nil, err
	}

	return data, nil
}

func (s *userService) setData(payload CreatePayload) *model.User {
	return &model.User{
		Email:        payload.Email,
		PasswordHash: payload.Password,
		FullName:     payload.FullName,
		PhoneNumber:  payload.PhoneNumber,
		Status:       enum.UNVERIFIED,
	}
}
