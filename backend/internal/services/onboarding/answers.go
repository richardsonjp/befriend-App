package onboarding

import (
	"bytes"
	"encoding/json"
	"fmt"
	"slices"
	"strings"
	"unicode/utf8"

	"befriend/internal/model"
	"befriend/internal/model/enum"
	customStr "befriend/pkg/utils/strings"
)

// normalizeAnswers checks answers against the question set: every question answered exactly once, no
// unknown questions, and each value valid for its question type. It returns the cleaned answers in
// question order. Free text is later sent to an LLM, so it's single-line and free of control and
// invisible characters.
func normalizeAnswers(questions []model.Question, answers []AnswerPayload) ([]model.Answer, error) {
	byID := make(map[string]json.RawMessage, len(answers))
	for _, a := range answers {
		if _, dup := byID[a.QuestionID]; dup {
			return nil, fmt.Errorf("%s is answered more than once", a.QuestionID)
		}
		byID[a.QuestionID] = a.Value
	}
	for _, a := range answers {
		if !slices.ContainsFunc(questions, func(q model.Question) bool { return q.ID == a.QuestionID }) {
			return nil, fmt.Errorf("%s is not a question in this set", a.QuestionID)
		}
	}

	normalized := make([]model.Answer, 0, len(questions))
	for _, q := range questions {
		raw, ok := byID[q.ID]
		if !ok {
			return nil, fmt.Errorf("%s is not answered", q.ID)
		}
		value, err := normalizeValue(q, raw)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", q.ID, err)
		}
		normalized = append(normalized, model.Answer{QuestionID: q.ID, Value: value})
	}
	return normalized, nil
}

func normalizeValue(q model.Question, raw json.RawMessage) (interface{}, error) {
	// json.Unmarshal of null leaves the target at its zero value without an error.
	if bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
		return nil, fmt.Errorf("must not be null")
	}

	switch q.Type {
	case enum.QUESTION_TEXT:
		var s string
		if err := json.Unmarshal(raw, &s); err != nil {
			return nil, fmt.Errorf("must be text")
		}
		if strings.IndexFunc(s, customStr.IsHiddenRune) >= 0 {
			return nil, fmt.Errorf("contains invisible or control characters")
		}
		s = strings.Join(strings.Fields(s), " ") // trim and collapse whitespace, including newlines
		if s == "" {
			return nil, fmt.Errorf("must not be empty")
		}
		if utf8.RuneCountInString(s) > q.MaxLength {
			return nil, fmt.Errorf("must be at most %d characters", q.MaxLength)
		}
		return s, nil

	case enum.QUESTION_CHOICE:
		var s string
		if err := json.Unmarshal(raw, &s); err != nil || !slices.Contains(q.Options, s) {
			return nil, fmt.Errorf("must be one of the listed options")
		}
		return s, nil

	case enum.QUESTION_SLIDER:
		var n int
		if err := json.Unmarshal(raw, &n); err != nil || n < q.Min || n > q.Max {
			return nil, fmt.Errorf("must be a whole number from %d to %d", q.Min, q.Max)
		}
		return n, nil

	default:
		return nil, fmt.Errorf("unsupported question type %q", q.Type)
	}
}
