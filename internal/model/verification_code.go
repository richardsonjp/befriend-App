package model

import (
	"time"
)

// TableName overrides the table name used by VerificationCode to `verification_code`
func (VerificationCode) TableName() string {
	return "verification_code"
}

type VerificationCode struct {
	ID        string    `gorm:"column:id;type:uuid;primaryKey;default:gen_random_uuid()"`
	UserID    string    `gorm:"column:user_id;type:uuid;not null;index:idx_verification_lookup,priority:1"`
	User      User      `gorm:"foreignKey:UserID;constraint:OnDelete:CASCADE"`                                        // Optional: if you want to preload User
	Type      string    `gorm:"column:table_type;type:varchar(50);not null;index:idx_verification_lookup,priority:3"` // 'user.email', 'user.phone', 'transaction', etc. (use table name as prefix, column name as suffix, e.g. 'user.email')
	Code      string    `gorm:"column:code;type:varchar(10);not null;index:idx_verification_lookup,priority:2"`
	ExpiresAt time.Time `gorm:"column:expires_at;not null"`
	CreatedAt time.Time `gorm:"column:created_at;type:timestamptz;default:now()"`
}
