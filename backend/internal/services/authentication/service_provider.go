package authentication

import (
	"context"

	"befriend/internal/model"
	"befriend/internal/model/enum"
	"befriend/internal/services/device"
	"befriend/internal/services/user_identity"
	"befriend/pkg/clients/idtoken"
	"befriend/pkg/utils/errors"
	"befriend/pkg/utils/logs"
)

// AuthenticateWithApple verifies a Sign in with Apple identity token and signs the linked account in
func (s *authenticationService) AuthenticateWithApple(ctx context.Context, payload AppleLogin) (*AuthenticateSessionResponse, error) {
	if s.appleVerifier == nil {
		return nil, errors.From("BAD_REQUEST").WithDetail("Sign in with Apple is not configured")
	}
	identity, err := s.appleVerifier.Verify(ctx, payload.IdentityToken, payload.Nonce)
	if err != nil {
		return nil, errors.From("UNAUTHORIZED").WithDetail("Invalid Apple identity token")
	}

	// Exchanged outside the transaction (network call). Sign-in still succeeds without it; the token
	// is only needed to revoke Apple access when the account is deleted.
	var appleRefreshToken *string
	if s.appleClient != nil && payload.AuthorizationCode != "" {
		token, err := s.appleClient.ExchangeCode(ctx, payload.AuthorizationCode, identity.Audience)
		if err != nil {
			logs.Log.Errorf("sign in with apple: code exchange failed: %v", err)
		} else {
			appleRefreshToken = &token
		}
	}

	return s.signInWithIdentity(ctx, enum.APPLE, identity, appleRefreshToken, payload.Device)
}

// AuthenticateWithGoogle verifies a Google ID token and signs the linked account in
func (s *authenticationService) AuthenticateWithGoogle(ctx context.Context, payload GoogleLogin) (*AuthenticateSessionResponse, error) {
	if s.googleVerifier == nil {
		return nil, errors.From("BAD_REQUEST").WithDetail("Google sign-in is not configured")
	}
	identity, err := s.googleVerifier.Verify(ctx, payload.IDToken, payload.Nonce)
	if err != nil {
		return nil, errors.From("UNAUTHORIZED").WithDetail("Invalid Google ID token")
	}
	return s.signInWithIdentity(ctx, enum.GOOGLE, identity, nil, payload.Device)
}

// signInWithIdentity links (or finds) the account for a verified identity, then registers the device and
// issues its session in one transaction.
func (s *authenticationService) signInWithIdentity(
	ctx context.Context,
	provider enum.IdentityProvider,
	identity *idtoken.Identity,
	appleRefreshToken *string,
	newDevice device.CreatePayload,
) (*AuthenticateSessionResponse, error) {
	var response *AuthenticateSessionResponse
	err := s.txRepo.Run(ctx, func(ctx context.Context) error {
		userData, err := s.resolveIdentityUser(ctx, provider, identity, appleRefreshToken)
		if err != nil {
			return err
		}
		if userData.Status != enum.ACTIVE {
			return errors.From("UNAUTHORIZED").WithDetail("Account is not active")
		}

		newDevice.UserID = userData.ID
		createdDevice, err := s.deviceService.Create(ctx, newDevice)
		if err != nil {
			return err
		}
		response, err = s.issueSession(ctx, userData.ID, createdDevice.ID)
		return err
	})
	if err != nil {
		return nil, err
	}
	return response, nil
}

// resolveIdentityUser returns the account for an identity, linking or creating it per decideLink.
// An Apple refresh token is stored with the audience (bundle ID) it was issued to, which revoking requires.
func (s *authenticationService) resolveIdentityUser(
	ctx context.Context,
	provider enum.IdentityProvider,
	identity *idtoken.Identity,
	appleRefreshToken *string,
) (*model.User, error) {
	linked, err := s.userIdentityService.GetByProviderSubject(ctx, provider, identity.Subject)
	if err != nil && !errors.Is(err, "DATA_NOT_FOUND") {
		return nil, err
	}

	usableEmail := identity.EmailVerified && identity.Email != ""
	var emailUser *model.User
	if linked == nil && usableEmail {
		emailUser, err = s.userService.GetUserByEmail(ctx, identity.Email)
		if err != nil && !errors.Is(err, "DATA_NOT_FOUND") {
			return nil, err
		}
	}

	var userData *model.User
	switch decideLink(linked != nil, emailUser, usableEmail) {
	case linkSignIn:
		if appleRefreshToken != nil {
			if err := s.userIdentityService.UpdateAppleRefreshToken(ctx, linked.ID, *appleRefreshToken, identity.Audience); err != nil {
				return nil, err
			}
		}
		return s.userService.GetUserByID(ctx, linked.UserID)

	case linkToExistingUser:
		userData = emailUser

	case linkTakeOverUnverified:
		if err := s.userService.ClaimForProvider(ctx, emailUser.ID); err != nil {
			return nil, err
		}
		emailUser.Status = enum.ACTIVE
		emailUser.PasswordHash = nil
		userData = emailUser

	case linkCreateUser:
		var email *string
		if usableEmail {
			email = &identity.Email
		}
		if userData, err = s.userService.CreateProviderUser(ctx, email); err != nil {
			return nil, err
		}
	}

	var appleClientID *string
	if appleRefreshToken != nil {
		appleClientID = &identity.Audience
	}
	_, err = s.userIdentityService.Create(ctx, user_identity.CreatePayload{
		UserID:            userData.ID,
		Provider:          provider,
		Subject:           identity.Subject,
		Email:             identity.Email,
		EmailVerified:     identity.EmailVerified,
		AppleRefreshToken: appleRefreshToken,
		AppleClientID:     appleClientID,
	})
	if err != nil {
		return nil, err
	}
	return userData, nil
}
