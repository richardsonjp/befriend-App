package model

import (
	"encoding/json"
	"time"

	ct "befriend/internal/model/custom_type"
	"befriend/internal/model/enum"
)

// TableName overrides the table name used by PersonalityVersion to `personality_version`
func (PersonalityVersion) TableName() string {
	return "personality_version"
}

type PersonalityStatus = enum.PersonalityStatus
type PersonalityReason = enum.PersonalityReason

// PersonalityVersion is one generated personality for a friend. The row doubles as its job in the
// generation queue; Personality and Phrasebook hold the validated JSON once it is ready.
type PersonalityVersion struct {
	ID                string                     `gorm:"primarykey;default:gen_random_uuid()"`
	FriendID          string                     `gorm:"column:friend_id"`
	Version           int                        `gorm:"column:version"`
	Status            PersonalityStatus          `gorm:"column:status"`
	Reason            PersonalityReason          `gorm:"column:reason"`
	SkinID            *string                    `gorm:"column:skin_id"` // reskin: the skin it writes for (nil = built-in)
	Model             *string                    `gorm:"column:model"`
	VocabularyVersion *int                       `gorm:"column:vocabulary_version"`
	Attempts          int                        `gorm:"column:attempts"`
	NextAttemptAt     time.Time                  `gorm:"column:next_attempt_at;default:now()"`
	LockedUntil       *time.Time                 `gorm:"column:locked_until"`
	Personality       *ct.JSONB[json.RawMessage] `gorm:"column:personality"`
	Phrasebook        *ct.JSONB[json.RawMessage] `gorm:"column:phrasebook"`
	Error             *string                    `gorm:"column:error"`
	CreatedAt         time.Time                  `gorm:"column:created_at;default:now()"`
	UpdatedAt         time.Time                  `gorm:"column:updated_at;default:now()"`
}
