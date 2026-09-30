package chat_sync

type KeyResponse struct {
	KeyID *string `json:"key_id"`
}

type PutRecordResponse struct {
	Seq     int64 `json:"seq"`
	Applied bool  `json:"applied"`
}

type RecordResponse struct {
	Kind       string `json:"kind"`
	ID         string `json:"id"`
	Seq        int64  `json:"seq"`
	ModifiedAt string `json:"modified_at"` // UTC, always 6 fractional digits
	Deleted    bool   `json:"deleted"`
	Blob       []byte `json:"blob,omitempty"` // standard base64; omitted for tombstones
}

type ListRecordsResponse struct {
	Records []RecordResponse `json:"records"`
	Next    int64            `json:"next"` // pass as ?after= for the next page
	More    bool             `json:"more"`
}

type ExchangeResponse struct {
	MacPublic      *string `json:"mac_public"`
	PhonePublic    *string `json:"phone_public"`
	SealedForMac   *string `json:"sealed_for_mac"`
	SealedForPhone *string `json:"sealed_for_phone"`
}
