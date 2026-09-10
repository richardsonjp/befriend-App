package model

import (
	ct "befriend/internal/model/custom_type"
	"befriend/internal/model/enum"
	"time"
)

// TableName overrides the table name used by User to `user`
func (User) TableName() string {
	return "user"
}

type UserStatus = enum.UserStatus

// User is one account. Email and PasswordHash are nil for Apple/Google-only accounts.
type User struct {
	ID              string     `gorm:"primarykey;default:gen_random_uuid()"`
	Email           *string    `gorm:"column:email"`
	PasswordHash    *string    `gorm:"column:password_hash"`
	Status          UserStatus `gorm:"column:status"`
	EmailVerifiedAt *time.Time `gorm:"column:email_verified_at"`
	// Activity sync settings: while paused, uploads are dropped; excluded app names are never stored.
	LogSyncPaused bool               `gorm:"column:log_sync_paused;default:false"`
	ExcludedApps  ct.JSONB[[]string] `gorm:"column:excluded_apps;default:'[]'"`
	CreatedAt     time.Time          `gorm:"column:created_at;default:now()"`
	UpdatedAt     time.Time          `gorm:"column:updated_at;default:now()"`
}
