package model

import "time"

// TableName overrides the table name used by TriggerEvent to `trigger_event`
func (TriggerEvent) TableName() string {
	return "trigger_event"
}

// TriggerEvent is one entry of the synced activity log (vocabulary trigger kinds).
type TriggerEvent struct {
	ID            string    `gorm:"primarykey;default:gen_random_uuid()"`
	UserID        string    `gorm:"column:user_id"`
	DeviceID      *string   `gorm:"column:device_id"`
	ClientEventID string    `gorm:"column:client_event_id"`
	Kind          string    `gorm:"column:kind"`
	AppName       *string   `gorm:"column:app_name"` // app_switched only
	Seconds       *int      `gorm:"column:seconds"`
	OccurredAt    time.Time `gorm:"column:occurred_at"`
	CreatedAt     time.Time `gorm:"column:created_at;default:now()"`
}
