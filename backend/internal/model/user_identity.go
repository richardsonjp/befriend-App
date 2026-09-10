package model

import (
	"befriend/internal/model/enum"
	"time"
)

// TableName overrides the table name used by UserIdentity to `user_identity`
func (UserIdentity) TableName() string {
	return "user_identity"
}

type IdentityProvider = enum.IdentityProvider

type UserIdentity struct {
	ID                string           `gorm:"primarykey;default:gen_random_uuid()"`
	UserID            string           `gorm:"column:user_id"`
	Provider          IdentityProvider `gorm:"column:provider"`
	Subject           string           `gorm:"column:subject"`
	Email             *string          `gorm:"column:email"`
	EmailVerified     bool             `gorm:"column:email_verified"`
	AppleRefreshToken *string          `gorm:"column:apple_refresh_token"`
	AppleClientID     *string          `gorm:"column:apple_client_id"` // bundle ID the refresh token was issued to
	CreatedAt         time.Time        `gorm:"column:created_at;default:now()"`
	UpdatedAt         time.Time        `gorm:"column:updated_at;default:now()"`
}
