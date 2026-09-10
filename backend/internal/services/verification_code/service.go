package verification_code

import (
	"context"
	"fmt"
	"time"

	"befriend/internal/model"
	"befriend/pkg/clients/email"
	"befriend/pkg/utils/errors"
	customStr "befriend/pkg/utils/strings"
)

const (
	USER_EMAIL_VERIFICATION = "user.email verification"
)

func (s *verificationCodeService) Create(ctx context.Context, payload CreatePayload) (*model.VerificationCode, error) {
	code, err := customStr.GenerateRandomNumericString(6)
	if err != nil {
		return nil, err
	}

	data := s.setData(payload, code)
	data, err = s.verificationCodeRepo.Create(ctx, data)
	if err != nil {
		return nil, err
	}
	return data, nil
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

func (s *verificationCodeService) Delete(ctx context.Context, payload DeletePayload) error {
	data, err := s.verificationCodeRepo.Get(ctx, payload.TableType, payload.UserID, payload.Code)
	if err != nil {
		return err
	}
	if data.ExpiresAt.Before(time.Now()) {
		return errors.From("VERIFICATION_CODE").WithDetail("verification code has expired")
	}

	err = s.verificationCodeRepo.Delete(ctx, payload.TableType, payload.UserID, payload.Code)
	if err != nil {
		return err
	}

	return nil
}

func (s *verificationCodeService) setData(payload CreatePayload, code string) *model.VerificationCode {
	return &model.VerificationCode{
		UserID:    payload.UserID,
		Type:      payload.TableType,
		Code:      code,
		ExpiresAt: payload.ExpiresAt,
	}
}
