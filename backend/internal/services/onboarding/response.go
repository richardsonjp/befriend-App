package onboarding

import "befriend/internal/model"

type QuestionsResponse struct {
	Version   int              `json:"version"`
	Questions []model.Question `json:"questions"`
}

// AnsweredQuestion pairs a question's prompt with the user's stored answer.
type AnsweredQuestion struct {
	Question string
	Answer   interface{}
}
