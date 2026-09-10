package device

import "time"

type CreatePayload struct {
	UserID   string `json:"-"`
	Platform string `json:"platform" validate:"required,oneof=ios macos"`
	Name     string `json:"name" validate:"required,max=100"`
}

// PushTokensPayload carries the device's APNs tokens (hex). Nil leaves a token unchanged; "" clears it.
type PushTokensPayload struct {
	UserID             string     `json:"-"`
	DeviceID           string     `json:"-"`
	APNsEnv            string     `json:"apns_env" validate:"required,oneof=sandbox production"`
	LAPushToStartToken *string    `json:"la_push_to_start_token" validate:"omitempty,max=512"`
	LAPushToken        *string    `json:"la_push_token" validate:"omitempty,max=512"`
	LAStartedAt        *time.Time `json:"la_started_at"` // required with a non-empty la_push_token
	WidgetPushToken    *string    `json:"widget_push_token" validate:"omitempty,max=512"`
}
