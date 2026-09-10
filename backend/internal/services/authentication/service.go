package authentication

import (
	"context"
	"befriend/internal/model/enum"
	"befriend/pkg/utils/errors"
	"befriend/pkg/utils/paseto"

	"golang.org/x/crypto/bcrypt"
)

// AuthenticateUser handles user login authentication
func (s *authenticationService) AuthenticateUser(ctx context.Context, params Login) (*AuthenticateSessionResponse, error) {
	// 1. Get user by email
	user, err := s.userService.GetUserByEmail(ctx, params.Email)
	if err != nil {
		return nil, errors.From("UNAUTHORIZED").WithDetail("Invalid credentials")
	}
	if user.Status == enum.UNVERIFIED {
		return nil, errors.From("UNAUTHORIZED").WithDetail("Email not verified")
	}

	if err = bcrypt.CompareHashAndPassword([]byte(user.PasswordHash), []byte(params.Password)); err != nil {
		return nil, errors.From("UNAUTHORIZED").WithDetail("Invalid credentials pass")
	}

	// 3. Get User Role
	accountMember, err := s.accountMemberService.GetAccountMemberByUserID(ctx, user.ID)
	if err != nil {
		return nil, errors.From("ROLE").WithDetail("Failed to get user role")
	}

	// 4. Generate Tokens
	accessToken, refreshToken, err := paseto.GenerateTokens(
		paseto.Claims{
			UserID: user.ID,
			RoleID: accountMember.RoleID,
		})
	if err != nil {
		return nil, errors.From("INTERNAL_SERVER_ERROR").WithDetail("Failed to generate tokens")
	}

	// 5. Get Frontend Path
	frontendPath, err := s.appResourceService.GetFrontendPathByRoleID(ctx, accountMember.RoleID)
	if err != nil {
		return nil, errors.From("INTERNAL_SERVER_ERROR").WithDetail("Failed to get user frontend path")
	}

	return &AuthenticateSessionResponse{
		AccessToken:  accessToken,
		RefreshToken: refreshToken,
		FrontendPath: frontendPath,
	}, nil
}

// AuthenticateOperator handles operator login authentication
func (s *authenticationService) AuthenticateOperator(ctx context.Context, params Login) (*AuthenticateSessionResponse, error) {
	// 1. Get operator by email
	operator, err := s.operatorService.GetOperatorByEmail(ctx, params.Email)
	if err != nil {
		return nil, errors.From("UNAUTHORIZED").WithDetail("Invalid credentials")
	}

	// 2. Verify Password
	if err = bcrypt.CompareHashAndPassword([]byte(operator.PasswordHash), []byte(params.Password)); err != nil {
		return nil, errors.From("UNAUTHORIZED").WithDetail("Invalid credentials")
	}

	// 3. Generate Tokens
	// Operators have a direct RoleID
	accessToken, refreshToken, err := paseto.GenerateTokens(
		paseto.Claims{
			OperatorID: operator.ID,
			RoleID:     operator.RoleID,
		})
	if err != nil {
		return nil, errors.From("INTERNAL_SERVER_ERROR").WithDetail("Failed to generate tokens")
	}

	// 4. Get Frontend Path (Optional for Operator, but good to have)
	frontendPath, err := s.appResourceService.GetFrontendPathByRoleID(ctx, operator.RoleID)
	if err != nil {
		// Log warning but maybe not fail? strict for now.
		return nil, errors.From("INTERNAL_SERVER_ERROR").WithDetail("Failed to get operator frontend path")
	}

	return &AuthenticateSessionResponse{
		AccessToken:  accessToken,
		RefreshToken: refreshToken,
		FrontendPath: frontendPath,
	}, nil
}

func (s *authenticationService) AuthenticateLogout(ctx context.Context, payload LogoutPayload) error {
	return nil
}
