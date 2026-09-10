package authentication

import (
	"context"

	"befriend/internal/model"
	"befriend/pkg/utils/logs"
)

// DeleteAccount deletes the user and everything hanging off it (cascading foreign keys), then revokes the
// app's Sign in with Apple authorization. Access tokens already issued stay valid until they expire.
func (s *authenticationService) DeleteAccount(ctx context.Context, userID string) error {
	var appleIdentities []model.UserIdentity
	err := s.txRepo.Run(ctx, func(ctx context.Context) error {
		identities, err := s.userIdentityService.ListAppleTokens(ctx, userID)
		if err != nil {
			return err
		}
		appleIdentities = identities
		return s.userService.DeleteUser(ctx, userID)
	})
	if err != nil {
		return err
	}

	// After the commit, so a failed delete leaves Apple sign-in working; in the background, so a slow Apple
	// endpoint doesn't hold the response. Best effort: the user can also remove the app in Apple ID settings.
	if len(appleIdentities) > 0 {
		go s.revokeAppleTokens(userID, appleIdentities)
	}
	return nil
}

func (s *authenticationService) revokeAppleTokens(userID string, identities []model.UserIdentity) {
	if s.appleClient == nil {
		logs.Log.Warnf("delete account %s: %d Apple token(s) not revoked, Apple server credentials not configured", userID, len(identities))
		return
	}
	for _, identity := range identities {
		if identity.AppleRefreshToken == nil || identity.AppleClientID == nil {
			continue
		}
		if err := s.appleClient.RevokeRefreshToken(context.Background(), *identity.AppleRefreshToken, *identity.AppleClientID); err != nil {
			logs.Log.Errorf("delete account %s: %v", userID, err)
		}
	}
}
