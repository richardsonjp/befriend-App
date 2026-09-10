package user_application

import (
	"context"
	"time"

	"befriend/config"
	"befriend/internal/model"
	"befriend/internal/model/enum"
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

// VerifyUserEmail activates the account when the latest emailed code matches
func (s *userApplicationService) VerifyUserEmail(ctx context.Context, payload VerifyEmailPayload) error {
	userData, err := s.userService.GetUserByEmail(ctx, payload.Email)
	if err != nil {
		if errors.Is(err, "DATA_NOT_FOUND") {
			return verification_code.InvalidCodeError()
		}
		return err
	}
	// Same answer as a wrong code, so this endpoint can't reveal which accounts are verified.
	if userData.Status != enum.UNVERIFIED {
		return verification_code.InvalidCodeError()
	}

	// Deliberately outside the transaction below, so a wrong guess stays counted.
	err = s.verificationCodeService.Check(ctx, verification_code.CheckPayload{
		UserID:    userData.ID,
		TableType: verification_code.USER_EMAIL_VERIFICATION,
		Code:      payload.OTPCode,
	})
	if err != nil {
		return err
	}

	return s.txRepo.Run(ctx, func(ctx context.Context) error {
		if err := s.userService.MarkEmailVerified(ctx, userData.ID); err != nil {
			return err
		}
		return s.verificationCodeService.DeleteAll(ctx, verification_code.USER_EMAIL_VERIFICATION, userData.ID)
	})
}

// ResendVerificationCode emails a fresh code to an unverified account. Unknown or already-verified
// emails get the same success reply, so this can't be used to probe accounts.
func (s *userApplicationService) ResendVerificationCode(ctx context.Context, payload ResendCodePayload) error {
	userData, err := s.userService.GetUserByEmail(ctx, payload.Email)
	if err != nil {
		if errors.Is(err, "DATA_NOT_FOUND") {
			return nil
		}
		return err
	}
	if userData.Status != enum.UNVERIFIED || userData.Email == nil {
		return nil
	}

	latest, err := s.verificationCodeService.GetLatest(ctx, verification_code.USER_EMAIL_VERIFICATION, userData.ID)
	if err != nil && !errors.Is(err, "DATA_NOT_FOUND") {
		return err
	}
	cooldown := time.Duration(config.Config.Verification.ResendCooldownSec) * time.Second
	// Inside the cooldown, succeed silently without sending: a distinct 429 would reveal that this
	// email belongs to an unverified account.
	if latest != nil && time.Since(latest.CreatedAt) < cooldown {
		return nil
	}

	var code *model.VerificationCode
	err = s.txRepo.Run(ctx, func(ctx context.Context) error {
		created, createErr := s.verificationCodeService.Create(ctx, verification_code.CreatePayload{
			UserID:    userData.ID,
			TableType: verification_code.USER_EMAIL_VERIFICATION,
			ExpiresAt: time.Now().Add(verificationCodeTTL),
		})
		code = created
		return createErr
	})
	if err != nil {
		return err
	}

	if err := s.verificationCodeService.SendVerificationEmail(ctx, *userData.Email, code); err != nil {
		return errors.From("VERIFICATION_CODE").WithDetail("the verification email could not be sent")
	}
	return nil
}
