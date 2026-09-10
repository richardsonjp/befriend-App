package model

import (
	"go-skeleton/internal/model/enum"
	"time"
)

// TableName overrides the table name used by User to `user`
func (User) TableName() string {
	return "user"
}

type UserStatus = enum.UserStatus
type User struct {
	ID              string     `gorm:"primarykey;default:gen_random_uuid()"`
	Email           string     `gorm:"column:email;unique;not null"`
	PasswordHash    string     `gorm:"column:password_hash;not null"`
	FullName        string     `gorm:"column:full_name"`
	PhoneNumber     string     `gorm:"column:phone_number;unique"`
	Status          UserStatus `gorm:"column:status"`
	EmailVerifiedAt *time.Time `gorm:"column:email_verified_at"`
	CreatedAt       time.Time  `gorm:"column:created_at;type:datetime;default:now()"`
	UpdatedAt       time.Time  `gorm:"column:updated_at;type:datetime;default:now()"`
}
