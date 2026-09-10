package model

import "time"

// TableName overrides the table name used by Presence to `presence`
func (Presence) TableName() string {
	return "presence"
}

// Presence tracks which of the user's devices holds the friend.
type Presence struct {
	UserID          string     `gorm:"primarykey;column:user_id"`
	Owner           string     `gorm:"column:owner"` // phone | mac
	PhoneClaimUntil *time.Time `gorm:"column:phone_claim_until"`
	MacActive       bool       `gorm:"column:mac_active"`
	MacSeenAt       *time.Time `gorm:"column:mac_seen_at"`
	ChangedAt       time.Time  `gorm:"column:changed_at"`
	LastPushAt      *time.Time `gorm:"column:last_push_at"`
}
