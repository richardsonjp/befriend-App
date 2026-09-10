package user_application

import (
	"context"

	"befriend/pkg/utils/errors"
)

// GetMe is what the apps need at launch: who is signed in and whether onboarding is done.
func (s *userApplicationService) GetMe(ctx context.Context, userID string) (*MeResponse, error) {
	userData, err := s.userService.GetUserByID(ctx, userID)
	if err != nil {
		return nil, err
	}

	_, err = s.friendService.GetByUserID(ctx, userID)
	if err != nil && !errors.Is(err, "DATA_NOT_FOUND") {
		return nil, err
	}

	return &MeResponse{
		ID:             userData.ID,
		Email:          userData.Email,
		OnboardingDone: err == nil,
	}, nil
}
