package model

import (
	"time"
)

// TableName overrides the table name used by Permission to `permission`
func (Permission) TableName() string {
	return "permission"
}

type Permission struct {
	ID          string    `gorm:"primarykey;default:gen_random_uuid()"`
	CategoryID  string    `gorm:"column:category_id"`
	Code        string    `gorm:"column:code;unique;not null"`
	Name        string    `gorm:"column:name;not null"`
	Description string    `gorm:"column:description"`
	CreatedAt   time.Time `gorm:"column:created_at;type:datetime;default:now()"`
}
