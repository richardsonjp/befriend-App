package model

import "time"

// TableName overrides the table name used by PairingCode to `pairing_code`
func (PairingCode) TableName() string {
	return "pairing_code"
}

// PairingCode is one QR pairing attempt from a Mac. The code and poll secret are stored hashed.
type PairingCode struct {
	ID             string     `gorm:"primarykey;default:gen_random_uuid()"`
	CodeHash       string     `gorm:"column:code_hash"`
	PollSecretHash string     `gorm:"column:poll_secret_hash"`
	DeviceName     string     `gorm:"column:device_name"`
	UserID         *string    `gorm:"column:user_id"` // set when an iPhone confirms
	ConfirmedAt    *time.Time `gorm:"column:confirmed_at"`
	ConsumedAt     *time.Time `gorm:"column:consumed_at"`
	ExpiresAt      time.Time  `gorm:"column:expires_at"`
	CreatedAt      time.Time  `gorm:"column:created_at;default:now()"`
}
