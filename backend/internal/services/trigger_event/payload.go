package trigger_event

import "time"

type RecordPayload struct {
	UserID   string         `json:"-"`
	DeviceID string         `json:"-"`
	Events   []EventPayload `json:"events" validate:"required,min=1,max=200,dive"`
}

type EventPayload struct {
	ClientEventID string    `json:"client_event_id" validate:"required,uuid"`
	Kind          string    `json:"kind" validate:"required,max=20"` // a vocabulary trigger kind
	AppName       *string   `json:"app_name" validate:"omitempty,max=200"`
	Seconds       *int      `json:"seconds" validate:"omitempty,min=0,max=31536000"`
	OccurredAt    time.Time `json:"occurred_at" validate:"required"`
}

type RecordResponse struct {
	// Accepted counts newly stored events; duplicates, excluded apps and events while paused aren't counted.
	Accepted int `json:"accepted"`
}
