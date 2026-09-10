package onboarding

import (
	"context"
)

// GetAnsweredQuestions returns the user's answers next to the question text they answered (from the
// question set version they saw), in question order.
func (s *onboardingService) GetAnsweredQuestions(ctx context.Context, userID string) ([]AnsweredQuestion, error) {
	response, err := s.onboardingResponseRepo.GetByUserID(ctx, userID)
	if err != nil {
		return nil, err
	}
	set, err := s.questionSetService.GetByID(ctx, response.QuestionSetID)
	if err != nil {
		return nil, err
	}

	prompts := make(map[string]string, len(set.Questions.Data))
	for _, q := range set.Questions.Data {
		prompts[q.ID] = q.Prompt
	}
	answered := make([]AnsweredQuestion, 0, len(response.Answers.Data))
	for _, a := range response.Answers.Data {
		answered = append(answered, AnsweredQuestion{Question: prompts[a.QuestionID], Answer: a.Value})
	}
	return answered, nil
}
