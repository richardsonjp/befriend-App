package onboarding

import "befriend/internal/model"

type QuestionsResponse struct {
	Version   int              `json:"version"`
	Questions []model.Question `json:"questions"`
}
