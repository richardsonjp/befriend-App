package model

import (
	"time"
)

// TableName overrides the table name used by RefreshToken to `refresh_token`
func (RefreshToken) TableName() string {
	return "refresh_token"
}

type RefreshToken struct {
	ID        string     `gorm:"primarykey;default:gen_random_uuid()"`
	UserID    string     `gorm:"column:user_id"`
	DeviceID  string     `gorm:"column:device_id"`
	TokenHash string     `gorm:"column:token_hash"`
	ExpiresAt time.Time  `gorm:"column:expires_at"`
	RotatedAt *time.Time `gorm:"column:rotated_at"`
	RevokedAt *time.Time `gorm:"column:revoked_at"`
	CreatedAt time.Time  `gorm:"column:created_at;default:now()"`
}
