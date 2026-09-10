package model

import (
	"befriend/internal/model/enum"
	"time"
)

// TableName overrides the table name used by PersonalityVersion to `personality_version`
func (PersonalityVersion) TableName() string {
	return "personality_version"
}

type PersonalityStatus = enum.PersonalityStatus
type PersonalityReason = enum.PersonalityReason

// PersonalityVersion is one generated personality for a friend. The personality and phrasebook
// columns are filled by the generation pipeline.
type PersonalityVersion struct {
	ID            string            `gorm:"primarykey;default:gen_random_uuid()"`
	FriendID      string            `gorm:"column:friend_id"`
	Version       int               `gorm:"column:version"`
	Status        PersonalityStatus `gorm:"column:status"`
	Reason        PersonalityReason `gorm:"column:reason"`
	Attempts      int               `gorm:"column:attempts"`
	NextAttemptAt time.Time         `gorm:"column:next_attempt_at;default:now()"`
	CreatedAt     time.Time         `gorm:"column:created_at;default:now()"`
	UpdatedAt     time.Time         `gorm:"column:updated_at;default:now()"`
}
