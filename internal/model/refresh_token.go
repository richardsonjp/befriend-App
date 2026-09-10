package model

import (
	"time"
)

// TableName overrides the table name used by RefreshToken to `refresh_token`
func (RefreshToken) TableName() string {
	return "refresh_token"
}

type RefreshToken struct {
	ID         string    `gorm:"primarykey;default:gen_random_uuid()"`
	UserID     string    `gorm:"column:user_id"`
	OperatorID string    `gorm:"column:operator_id"`
	TokenHash  string    `gorm:"column:token_hash;unique;not null"`
	DeviceInfo string    `gorm:"column:device_info"`
	IPAddress  string    `gorm:"column:ip_address"`
	ExpiresAt  time.Time `gorm:"column:expires_at;not null;type:datetime"`
	CreatedAt  time.Time `gorm:"column:created_at;type:datetime;default:now()"`
}
