package verification_code

import (
	"context"
	"crypto/subtle"
	"fmt"
	"time"

	"befriend/internal/model"
	"befriend/pkg/clients/email"
	"befriend/pkg/utils/errors"
	customStr "befriend/pkg/utils/strings"
)

const (
	USER_EMAIL_VERIFICATION = "user.email verification"

	// maxAttempts wrong tries lock a code; the user has to request a new one.
	maxAttempts = 5
)

// InvalidCodeError is the single answer for every failed verification (wrong, expired, locked,
// unknown account), so a caller can't learn which case it hit.
func InvalidCodeError() error {
	return errors.From("VERIFICATION_CODE").WithDetail("invalid or expired verification code")
}

// Create issues a new code, replacing any earlier code for the same user and purpose.
func (s *verificationCodeService) Create(ctx context.Context, payload CreatePayload) (*model.VerificationCode, error) {
	code, err := customStr.GenerateRandomNumericString(6)
	if err != nil {
		return nil, err
	}

	if err := s.verificationCodeRepo.DeleteAll(ctx, payload.TableType, payload.UserID); err != nil {
		return nil, err
	}

	return s.verificationCodeRepo.Create(ctx, &model.VerificationCode{
		UserID:    payload.UserID,
		Type:      payload.TableType,
		Code:      code,
		ExpiresAt: payload.ExpiresAt,
	})
}

func (s *verificationCodeService) GetLatest(ctx context.Context, tableType, userID string) (*model.VerificationCode, error) {
	return s.verificationCodeRepo.GetLatest(ctx, tableType, userID)
}

// Check accepts or rejects a submitted code. Call it outside a transaction: a wrong guess must stay
// counted even though the request fails.
func (s *verificationCodeService) Check(ctx context.Context, payload CheckPayload) error {
	data, err := s.verificationCodeRepo.GetLatest(ctx, payload.TableType, payload.UserID)
	if err != nil {
		if errors.Is(err, "DATA_NOT_FOUND") {
			return InvalidCodeError()
		}
		return err
	}

	accepted, countAttempt := evaluateCode(data, payload.Code, time.Now())
	if countAttempt {
		if err := s.verificationCodeRepo.IncrementAttempts(ctx, data.ID); err != nil {
			return err
		}
	}
	if !accepted {
		return InvalidCodeError()
	}
	return nil
}

func (s *verificationCodeService) DeleteAll(ctx context.Context, tableType, userID string) error {
	return s.verificationCodeRepo.DeleteAll(ctx, tableType, userID)
}

// SendVerificationEmail mails an already-created code. Call it after the transaction that created
// the code has committed, so a slow mail server never holds a database transaction open.
func (s *verificationCodeService) SendVerificationEmail(ctx context.Context, emailAddress string, data *model.VerificationCode) error {
	return s.smtpClient.SendEmail(&email.EmailRequest{
		To:      []string{emailAddress},
		Subject: "Your befriend verification code",
		Body: fmt.Sprintf("Your befriend verification code is %s. It expires in %d minutes.",
			data.Code, int(time.Until(data.ExpiresAt).Round(time.Minute).Minutes())),
		IsHTML: false,
	})
}

// evaluateCode decides whether a submitted code is accepted, and whether a rejection counts toward
// the attempt limit. Expired or locked codes are refused without counting; comparison is constant-time.
func evaluateCode(data *model.VerificationCode, submitted string, now time.Time) (accepted, countAttempt bool) {
	if !now.Before(data.ExpiresAt) || data.Attempts >= maxAttempts {
		return false, false
	}
	if subtle.ConstantTimeCompare([]byte(data.Code), []byte(submitted)) == 1 {
		return true, false
	}
	return false, true
}
