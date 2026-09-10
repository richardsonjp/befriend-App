package verification_code

import (
	"context"
	"fmt"
	"go-skeleton/internal/model"
	"go-skeleton/pkg/clients/email"
	"go-skeleton/pkg/utils/errors"
	customStr "go-skeleton/pkg/utils/strings"
	"time"
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

func (s *verificationCodeService) SendVerificationEmail(ctx context.Context, payload CreatePayload) error {
	data, err := s.Create(ctx, payload)
	if err != nil {
		return err
	}

	return nil

	// TODO: bypass for now because we got no valid email config
	return s.smtpClient.SendEmail(&email.EmailRequest{
		To:      []string{data.UserID},
		Subject: "Verification Code",
		Body:    fmt.Sprintf("Your verification code is %s", data.Code),
		IsHTML:  false,
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
