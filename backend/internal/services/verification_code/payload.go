package verification_code

import "time"

type CreatePayload struct {
	UserID    string
	TableType string
	ExpiresAt time.Time
}

type CheckPayload struct {
	UserID    string
	TableType string
	Code      string
}
