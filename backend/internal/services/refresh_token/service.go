package refresh_token

import (
	"context"
	"time"

	"befriend/internal/model"
)

// Decision is what to do with a presented refresh token.
type Decision int

const (
	DecisionRotate        Decision = iota // issue a new pair
	DecisionReject                        // revoked or expired
	DecisionReuseDetected                 // rotated long ago and presented again: treat as stolen
)

func (s *refreshTokenService) Create(ctx context.Context, payload CreatePayload) error {
	return s.refreshTokenRepo.Create(ctx, &model.RefreshToken{
		UserID:    payload.UserID,
		DeviceID:  payload.DeviceID,
		TokenHash: payload.TokenHash,
		ExpiresAt: payload.ExpiresAt,
	})
}

// GetForRotation loads and locks the token row; call it inside a transaction.
func (s *refreshTokenService) GetForRotation(ctx context.Context, tokenHash string) (*model.RefreshToken, error) {
	return s.refreshTokenRepo.GetByHashForUpdate(ctx, tokenHash)
}

func (s *refreshTokenService) MarkRotated(ctx context.Context, id string) error {
	return s.refreshTokenRepo.MarkRotated(ctx, id, time.Now())
}

func (s *refreshTokenService) RevokeByDevice(ctx context.Context, deviceID string) error {
	return s.refreshTokenRepo.RevokeByDevice(ctx, deviceID, time.Now())
}

// Decide what to do with a presented refresh token. A token already rotated within the grace window
// is accepted again, so the app, widget and intents refreshing at the same moment don't lock each other
// out. One presented after the window has leaked, so the caller should sign the whole device out.
func Decide(token *model.RefreshToken, now time.Time, grace time.Duration) Decision {
	switch {
	case token.RevokedAt != nil || !now.Before(token.ExpiresAt):
		return DecisionReject
	case token.RotatedAt != nil && now.Sub(*token.RotatedAt) > grace:
		return DecisionReuseDetected
	default:
		return DecisionRotate
	}
}
