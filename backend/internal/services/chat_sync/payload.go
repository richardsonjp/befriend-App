package chat_sync

import "time"

type KeyPayload struct {
	UserID string `json:"-"`
	KeyID  string `json:"key_id" validate:"required,min=8,max=128"`
}

type RecordPayload struct {
	UserID     string    `json:"-"`
	Kind       string    `json:"-" validate:"oneof=conversation document"` // from the path
	ID         string    `json:"-" validate:"required,uuid"`               // from the path, lowercased
	ModifiedAt time.Time `json:"modified_at" validate:"required"`
	Deleted    bool      `json:"deleted"`
	Blob       []byte    `json:"blob"` // standard base64 in JSON; required unless deleted
}

type ListRecordsPayload struct {
	UserID string `query:"-"`
	After  int64  `query:"after" validate:"min=0"`
	Limit  int    `query:"limit" validate:"omitempty,min=1,max=200"` // 0: DefaultPullLimit
}

type ExchangePayload struct {
	UserID         string `json:"-"`
	ID             string `json:"-" validate:"required,uuid"` // from the path, lowercased
	MacPublic      string `json:"mac_public" validate:"omitempty,max=1024,base64"`
	PhonePublic    string `json:"phone_public" validate:"omitempty,max=1024,base64"`
	SealedForMac   string `json:"sealed_for_mac" validate:"omitempty,max=1024,base64"`
	SealedForPhone string `json:"sealed_for_phone" validate:"omitempty,max=1024,base64"`
}
