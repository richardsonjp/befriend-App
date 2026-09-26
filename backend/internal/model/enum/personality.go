package enum

import (
	"database/sql/driver"
	"fmt"
)

type PersonalityStatus int64

// Scan for converting byte to string for fetching/read
func (s *PersonalityStatus) Scan(value interface{}) error {
	key, err := scanString(value)
	if err != nil {
		return err
	}
	for i, v := range PersonalityStatusKey {
		if v == key {
			*s = i
			return nil
		}
	}
	return fmt.Errorf("unknown personality status %q", key)
}

// Value for converting enum to string for storing/write
func (s PersonalityStatus) Value() (driver.Value, error) {
	return s.String(), nil
}

const (
	PERSONALITY_PENDING PersonalityStatus = iota + 1
	PERSONALITY_RUNNING
	PERSONALITY_READY
	PERSONALITY_FAILED
	// PERSONALITY_ABANDONED is never retried: a reskin that failed or was superseded by another pick.
	PERSONALITY_ABANDONED
)

var PersonalityStatusKey = map[PersonalityStatus]string{
	PERSONALITY_PENDING:   "pending",
	PERSONALITY_RUNNING:   "running",
	PERSONALITY_READY:     "ready",
	PERSONALITY_FAILED:    "failed",
	PERSONALITY_ABANDONED: "abandoned",
}

// String for stringify PersonalityStatus
func (s PersonalityStatus) String() string {
	return PersonalityStatusKey[s]
}

type PersonalityReason int64

// Scan for converting byte to string for fetching/read
func (s *PersonalityReason) Scan(value interface{}) error {
	key, err := scanString(value)
	if err != nil {
		return err
	}
	for i, v := range PersonalityReasonKey {
		if v == key {
			*s = i
			return nil
		}
	}
	return fmt.Errorf("unknown personality reason %q", key)
}

// Value for converting enum to string for storing/write
func (s PersonalityReason) Value() (driver.Value, error) {
	return s.String(), nil
}

const (
	REASON_ONBOARDING PersonalityReason = iota + 1
	REASON_EVOLUTION
	// REASON_RESKIN writes a phrasebook for the skin the user picked; the pick applies once it is ready.
	REASON_RESKIN
)

var PersonalityReasonKey = map[PersonalityReason]string{
	REASON_ONBOARDING: "onboarding",
	REASON_EVOLUTION:  "evolution",
	REASON_RESKIN:     "reskin",
}

// String for stringify PersonalityReason
func (s PersonalityReason) String() string {
	return PersonalityReasonKey[s]
}

// QuestionType is the kind of onboarding question. It lives inside question_set JSON, not its own column,
// so it's a plain string.
type QuestionType string

const (
	QUESTION_TEXT   QuestionType = "text"
	QUESTION_CHOICE QuestionType = "choice"
	QUESTION_SLIDER QuestionType = "slider"
)
