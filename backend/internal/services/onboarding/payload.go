package onboarding

import "encoding/json"

type CompletePayload struct {
	QuestionSetVersion int              `json:"question_set_version" validate:"required,min=1"`
	Answers            []AnswerPayload  `json:"answers" validate:"required,min=1,max=50,dive"`
	Timezone           string           `json:"timezone" validate:"required,max=64"` // IANA name, e.g. Asia/Jakarta
	Location           *LocationPayload `json:"location"`                            // optional: city-level birthplace
	Consent            bool             `json:"consent" validate:"required"`         // must be true
}

type AnswerPayload struct {
	QuestionID string          `json:"question_id" validate:"required,max=64"`
	Value      json.RawMessage `json:"value" validate:"required"` // string for text/choice, integer for slider
}

type LocationPayload struct {
	City        string   `json:"city" validate:"omitempty,max=100"`
	CountryCode string   `json:"country_code" validate:"omitempty,len=2,alpha"`
	Latitude    *float64 `json:"latitude" validate:"required_with=Longitude,omitempty,min=-90,max=90"` // both or neither
	Longitude   *float64 `json:"longitude" validate:"required_with=Latitude,omitempty,min=-180,max=180"`
}
