package user_application

import (
	"context"
	"fmt"
	"go-skeleton/internal/model/enum"
	"go-skeleton/internal/services/account"
	"go-skeleton/internal/services/account_member"
	"go-skeleton/internal/services/user"
	"go-skeleton/internal/services/verification_code"
	"go-skeleton/pkg/utils/errors"
	"time"
)

// Register handles the complete user registration flow
func (s *userApplicationService) Register(ctx context.Context, payload RegisterPayload) error {
	return s.txRepo.Run(ctx, func(ctx context.Context) error {
		if payload.AccountType == enum.PERSONAL.String() {
			payload.AccountName = payload.FullName // if account type is personal, use full name as account name
		}
		newAccount, err := s.accountService.CreateAccount(ctx, account.CreatePayload{
			Name: payload.AccountName,
			Type: payload.AccountType,
		})
		if err != nil {
			return errors.From("ACCOUNT").WithDetail(fmt.Sprintf("Failed to create account: %v", err))
		}

		newUser, err := s.userService.CreateUser(ctx, user.CreatePayload{
			FullName:    payload.FullName,
			Email:       payload.Email,
			PhoneNumber: payload.PhoneNumber,
			Password:    payload.Password,
		})
		if err != nil {
			return errors.From("USER").WithDetail(fmt.Sprintf("failed to create user: %v", err))
		}

		newRole, err := s.roleService.CreateSystemDefaultRoles(ctx, newAccount.Type, newAccount.ID)
		if err != nil {
			return errors.From("ROLE").WithDetail(fmt.Sprintf("failed to create system default roles: %v", err))
		}

		_, err = s.accountMemberService.CreateAccountMember(ctx, account_member.CreatePayload{
			AccountID: newAccount.ID,
			UserID:    newUser.ID,
			RoleID:    newRole.ID,
		})
		if err != nil {
			return errors.From("ACCOUNT_MEMBER").WithDetail(fmt.Sprintf("failed to create account member: %v", err))
		}

		err = s.verificationCodeService.SendVerificationEmail(ctx, verification_code.CreatePayload{
			UserID:    newUser.ID,
			TableType: verification_code.USER_EMAIL_VERIFICATION,
			ExpiresAt: time.Now().Add(5 * time.Minute),
		})
		if err != nil {
			return errors.From("VERIFICATION_CODE").WithDetail(fmt.Sprintf("failed to create verification code: %v", err))
		}

		return nil
	})
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
