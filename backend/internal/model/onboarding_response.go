package model

import (
	ct "befriend/internal/model/custom_type"
	"time"
)

// TableName overrides the table name used by OnboardingResponse to `onboarding_response`
func (OnboardingResponse) TableName() string {
	return "onboarding_response"
}

// Answer is a validated answer: a string for text/choice questions, an int for sliders.
type Answer struct {
	QuestionID string      `json:"question_id"`
	Value      interface{} `json:"value"`
}

type OnboardingResponse struct {
	UserID        string             `gorm:"primarykey;column:user_id"`
	QuestionSetID string             `gorm:"column:question_set_id"`
	Answers       ct.JSONB[[]Answer] `gorm:"column:answers"`
	ConsentAt     time.Time          `gorm:"column:consent_at"`
	CompletedAt   time.Time          `gorm:"column:completed_at;default:now()"`
}
