package user_application

import (
	"context"
	"fmt"
	"time"

	"befriend/internal/model"
	"befriend/internal/services/user"
	"befriend/internal/services/verification_code"
	"befriend/pkg/utils/errors"
)

const verificationCodeTTL = 10 * time.Minute

// Register creates an unverified email/password user and emails the verification code
func (s *userApplicationService) Register(ctx context.Context, payload RegisterPayload) error {
	var newUser *model.User
	var code *model.VerificationCode
	err := s.txRepo.Run(ctx, func(ctx context.Context) error {
		_, err := s.userService.GetUserByEmail(ctx, payload.Email)
		if err == nil {
			return errors.From("USER").WithDetail("email is already registered")
		}
		if !errors.Is(err, "DATA_NOT_FOUND") {
			return err
		}

		newUser, err = s.userService.CreateUser(ctx, user.CreatePayload{
			Email:    payload.Email,
			Password: payload.Password,
		})
		if err != nil {
			// A concurrent registration can win the race past the check above.
			if errors.Is(err, "DATA_CONFLICT") {
				return errors.From("USER").WithDetail("email is already registered")
			}
			return err
		}

		code, err = s.verificationCodeService.Create(ctx, verification_code.CreatePayload{
			UserID:    newUser.ID,
			TableType: verification_code.USER_EMAIL_VERIFICATION,
			ExpiresAt: time.Now().Add(verificationCodeTTL),
		})
		return err
	})
	if err != nil {
		return err
	}

	// Mail after commit: a slow or failing SMTP server must never hold the transaction open.
	if err := s.verificationCodeService.SendVerificationEmail(ctx, *newUser.Email, code); err != nil {
		return errors.From("VERIFICATION_CODE").WithDetail("account created, but the verification email could not be sent")
	}

	return nil
}

func (s *userApplicationService) VerifyUserEmail(ctx context.Context, payload VerifyEmailPayload) error {
	return s.txRepo.Run(ctx, func(ctx context.Context) error {
		userData, err := s.userService.UpdateEmailVerified(ctx, payload.Email)
		if err != nil {
			return errors.From("USER").WithDetail(fmt.Sprintf("failed to update user email verified: %v", err))
		}

		err = s.verificationCodeService.Delete(ctx, verification_code.DeletePayload{
			UserID:    userData.ID,
			TableType: verification_code.USER_EMAIL_VERIFICATION,
			Code:      payload.OTPCode,
		})
		if err != nil {
			return errors.From("VERIFICATION_CODE").WithDetail(fmt.Sprintf("failed to delete verification code: %v", err))
		}

		return nil
	})
}
