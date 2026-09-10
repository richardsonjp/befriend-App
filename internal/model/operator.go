package model

import (
	"time"
)

// TableName overrides the table name used by Operator to `operator`
func (Operator) TableName() string {
	return "operator"
}

type Operator struct {
	ID           string    `gorm:"primarykey;default:gen_random_uuid()"`
	Email        string    `gorm:"column:email;unique;not null"`
	PasswordHash string    `gorm:"column:password_hash;not null"`
	FullName     string    `gorm:"column:full_name"`
	RoleID       string    `gorm:"column:role_id"`
	IsActive     bool      `gorm:"column:is_active;default:true"`
	CreatedAt    time.Time `gorm:"column:created_at;type:datetime;default:now()"`
}
