package verification_code

import "time"

type CreatePayload struct {
	UserID    string
	Email     string
	TableType string
	ExpiresAt time.Time
}

type DeletePayload struct {
	UserID    string
	TableType string
	Code      string
}
