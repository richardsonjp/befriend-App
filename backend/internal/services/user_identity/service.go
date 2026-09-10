package user_identity

import (
	"context"

	"befriend/internal/model"
	"befriend/internal/model/enum"
)

func (s *userIdentityService) Create(ctx context.Context, payload CreatePayload) (*model.UserIdentity, error) {
	m := &model.UserIdentity{
		UserID:            payload.UserID,
		Provider:          payload.Provider,
		Subject:           payload.Subject,
		EmailVerified:     payload.EmailVerified,
		AppleRefreshToken: payload.AppleRefreshToken,
	}
	if payload.Email != "" {
		email := payload.Email
		m.Email = &email
	}
	return s.userIdentityRepo.Create(ctx, m)
}

func (s *userIdentityService) GetByProviderSubject(ctx context.Context, provider enum.IdentityProvider, subject string) (*model.UserIdentity, error) {
	return s.userIdentityRepo.GetByProviderSubject(ctx, provider, subject)
}

func (s *userIdentityService) UpdateAppleRefreshToken(ctx context.Context, id, token string) error {
	return s.userIdentityRepo.UpdateAppleRefreshToken(ctx, id, token)
}
