package model

import (
	"time"
)

// TableName overrides the table name used by VerificationCode to `verification_code`
func (VerificationCode) TableName() string {
	return "verification_code"
}

type VerificationCode struct {
	ID        string    `gorm:"column:id;primaryKey;default:gen_random_uuid()"`
	UserID    string    `gorm:"column:user_id"`
	Type      string    `gorm:"column:table_type"` // table name prefix + column suffix, e.g. 'user.email verification'
	Code      string    `gorm:"column:code"`
	Attempts  int       `gorm:"column:attempts"`
	ExpiresAt time.Time `gorm:"column:expires_at"`
	CreatedAt time.Time `gorm:"column:created_at;default:now()"`
}
