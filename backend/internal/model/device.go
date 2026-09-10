package model

import (
	"befriend/internal/model/enum"
	"time"
)

// TableName overrides the table name used by Device to `device`
func (Device) TableName() string {
	return "device"
}

type DevicePlatform = enum.DevicePlatform

type Device struct {
	ID         string         `gorm:"primarykey;default:gen_random_uuid()"`
	UserID     string         `gorm:"column:user_id"`
	Platform   DevicePlatform `gorm:"column:platform"`
	Name       string         `gorm:"column:name"`
	LastSeenAt time.Time      `gorm:"column:last_seen_at;default:now()"`
	CreatedAt  time.Time      `gorm:"column:created_at;default:now()"`
	UpdatedAt  time.Time      `gorm:"column:updated_at;default:now()"`
}
