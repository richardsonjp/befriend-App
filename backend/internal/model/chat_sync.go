package model

import "time"

// TableName overrides the table name used by ChatSyncKey to `chat_sync_keys`
func (ChatSyncKey) TableName() string {
	return "chat_sync_keys"
}

// ChatSyncKey is the fingerprint of the key a user's devices encrypt synced chats with.
type ChatSyncKey struct {
	UserID    string    `gorm:"primarykey;column:user_id"`
	KeyID     string    `gorm:"column:key_id"`
	CreatedAt time.Time `gorm:"column:created_at;default:now()"`
}

// TableName overrides the table name used by ChatRecord to `chat_records`
func (ChatRecord) TableName() string {
	return "chat_records"
}

// ChatRecord is one encrypted conversation or document. Blob is opaque ciphertext; nil for a tombstone.
type ChatRecord struct {
	UserID     string    `gorm:"primarykey;column:user_id"`
	Kind       string    `gorm:"primarykey;column:kind"`
	RecordID   string    `gorm:"primarykey;column:record_id"`
	Seq        int64     `gorm:"column:seq"`
	ModifiedAt time.Time `gorm:"column:modified_at"`
	Deleted    bool      `gorm:"column:deleted"`
	Blob       []byte    `gorm:"column:blob"`
	Size       int       `gorm:"column:size"`
	UpdatedAt  time.Time `gorm:"column:updated_at;default:now()"`
}

// TableName overrides the table name used by ChatKeyExchange to `chat_key_exchanges`
func (ChatKeyExchange) TableName() string {
	return "chat_key_exchanges"
}

// ChatKeyExchange hands the chat sync key between a user's Mac and iPhone (public keys, then sealed keys).
type ChatKeyExchange struct {
	ID             string    `gorm:"primarykey;column:id"`
	UserID         string    `gorm:"column:user_id"`
	MacPublic      *string   `gorm:"column:mac_public"`
	PhonePublic    *string   `gorm:"column:phone_public"`
	SealedForMac   *string   `gorm:"column:sealed_for_mac"`
	SealedForPhone *string   `gorm:"column:sealed_for_phone"`
	CreatedAt      time.Time `gorm:"column:created_at;default:now()"`
	ExpiresAt      time.Time `gorm:"column:expires_at"`
}
