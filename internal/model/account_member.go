package model

import (
	"time"
)

// TableName overrides the table name used by AccountMember to `account_member`
func (AccountMember) TableName() string {
	return "account_member"
}

type AccountMember struct {
	ID        string    `gorm:"primarykey;default:gen_random_uuid()"`
	AccountID string    `gorm:"column:account_id"`
	UserID    string    `gorm:"column:user_id"`
	RoleID    string    `gorm:"column:role_id"`
	JoinedAt  time.Time `gorm:"column:joined_at;type:datetime;default:now()"`
}
