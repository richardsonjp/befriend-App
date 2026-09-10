package onboarding

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"

	"befriend/internal/model"
	"befriend/internal/model/enum"
)

var testQuestions = []model.Question{
	{ID: "friend_name", Type: enum.QUESTION_TEXT, MaxLength: 24},
	{ID: "humor", Type: enum.QUESTION_CHOICE, Options: []string{"Puns", "Sarcasm"}},
	{ID: "energy", Type: enum.QUESTION_SLIDER, Min: 1, Max: 10},
}

func answer(id string, value interface{}) AnswerPayload {
	raw, _ := json.Marshal(value)
	return AnswerPayload{QuestionID: id, Value: raw}
}

func TestNormalizeAnswers(t *testing.T) {
	valid := func(name interface{}, humor interface{}, energy interface{}) []AnswerPayload {
		return []AnswerPayload{answer("energy", energy), answer("friend_name", name), answer("humor", humor)}
	}

	tests := []struct {
		name    string
		answers []AnswerPayload
		want    []model.Answer
		wantErr string
	}{
		{
			name:    "valid answers come back in question order",
			answers: valid("Mochi", "Puns", 7),
			want: []model.Answer{
				{QuestionID: "friend_name", Value: "Mochi"},
				{QuestionID: "humor", Value: "Puns"},
				{QuestionID: "energy", Value: 7},
			},
		},
		{
			name:    "text is trimmed and whitespace collapsed, newlines included",
			answers: valid("  Little \n\t Mochi  ", "Sarcasm", 1),
			want: []model.Answer{
				{QuestionID: "friend_name", Value: "Little Mochi"},
				{QuestionID: "humor", Value: "Sarcasm"},
				{QuestionID: "energy", Value: 1},
			},
		},
		{name: "text at the character limit (multibyte) is fine", answers: valid(strings.Repeat("é", 24), "Puns", 10)},
		{name: "emoji joined with a zero-width joiner is fine", answers: valid("Dev 👩\u200d💻", "Puns", 3)},
		{name: "text over the character limit", answers: valid(strings.Repeat("a", 25), "Puns", 5), wantErr: "at most 24"},
		{name: "blank text", answers: valid("   ", "Puns", 5), wantErr: "not be empty"},
		{name: "control characters rejected", answers: valid("Mo\achi", "Puns", 5), wantErr: "control characters"},
		{name: "zero-width space rejected", answers: valid("Mo\u200bchi", "Puns", 5), wantErr: "invisible"},
		{name: "right-to-left override rejected", answers: valid("Mochi\u202eihcoM", "Puns", 5), wantErr: "invisible"},
		{name: "text given as a number", answers: valid(42, "Puns", 5), wantErr: "must be text"},
		{name: "text given as null", answers: valid(nil, "Puns", 5), wantErr: "not be null"},
		{name: "choice not in options", answers: valid("Mochi", "Slapstick", 5), wantErr: "listed options"},
		{name: "choice differs only in case", answers: valid("Mochi", "puns", 5), wantErr: "listed options"},
		{name: "slider below range", answers: valid("Mochi", "Puns", 0), wantErr: "from 1 to 10"},
		{name: "slider above range", answers: valid("Mochi", "Puns", 11), wantErr: "from 1 to 10"},
		{name: "slider not a whole number", answers: valid("Mochi", "Puns", 5.5), wantErr: "whole number"},
		{name: "slider given as text", answers: valid("Mochi", "Puns", "5"), wantErr: "whole number"},
		{name: "slider given as null", answers: valid("Mochi", "Puns", nil), wantErr: "not be null"},
		{name: "missing answer", answers: []AnswerPayload{answer("friend_name", "Mochi"), answer("humor", "Puns")}, wantErr: "energy is not answered"},
		{name: "duplicate answer", answers: append(valid("Mochi", "Puns", 5), answer("humor", "Sarcasm")), wantErr: "more than once"},
		{name: "unknown question", answers: append(valid("Mochi", "Puns", 5), answer("shoe_size", "42")), wantErr: "not a question"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := normalizeAnswers(testQuestions, tt.answers)
			if tt.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), tt.wantErr) {
					t.Fatalf("error = %v; want one containing %q", err, tt.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if tt.want != nil && !reflect.DeepEqual(got, tt.want) {
				t.Fatalf("got %+v\nwant %+v", got, tt.want)
			}
		})
	}
}
