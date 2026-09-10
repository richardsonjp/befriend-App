package model

import (
	ct "befriend/internal/model/custom_type"
	"befriend/internal/model/enum"
	"time"
)

// TableName overrides the table name used by QuestionSet to `question_set`
func (QuestionSet) TableName() string {
	return "question_set"
}

type QuestionType = enum.QuestionType

// Question is one onboarding question inside a question set.
type Question struct {
	ID        string       `json:"id"`
	Type      QuestionType `json:"type"`
	Prompt    string       `json:"prompt"`
	Options   []string     `json:"options,omitempty"`    // choice
	MaxLength int          `json:"max_length,omitempty"` // text, in characters
	Min       int          `json:"min,omitempty"`        // slider
	Max       int          `json:"max,omitempty"`        // slider
	MinLabel  string       `json:"min_label,omitempty"`  // slider
	MaxLabel  string       `json:"max_label,omitempty"`  // slider
}

type QuestionSet struct {
	ID        string               `gorm:"primarykey;default:gen_random_uuid()"`
	Version   int                  `gorm:"column:version"`
	Questions ct.JSONB[[]Question] `gorm:"column:questions"`
	IsActive  bool                 `gorm:"column:is_active"`
	CreatedAt time.Time            `gorm:"column:created_at;default:now()"`
}
