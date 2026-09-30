package chat_sync

import (
	"context"

	repoChatSync "befriend/internal/repositories/chat_sync"
	"befriend/internal/repositories/tx"
)

// ChatSyncService stores a user's end-to-end-encrypted chats. Blobs are opaque ciphertext: never parse them.
type ChatSyncService interface {
	GetKey(ctx context.Context, userID string) (*KeyResponse, error)
	// SetKey stores the key id if the user has none; CHAT_KEY_MISMATCH if a different one is stored.
	SetKey(ctx context.Context, payload KeyPayload) (*KeyResponse, error)
	// PutRecord applies the write unless a later one is stored (last writer wins by modified_at).
	PutRecord(ctx context.Context, payload RecordPayload) (*PutRecordResponse, error)
	// ListRecords returns the user's records changed after a seq, oldest change first.
	ListRecords(ctx context.Context, payload ListRecordsPayload) (*ListRecordsResponse, error)
	// PutExchange creates or fills in a key exchange; filled fields never change (CHAT_EXCHANGE_CONFLICT).
	PutExchange(ctx context.Context, payload ExchangePayload) (*ExchangeResponse, error)
	// GetExchange returns CHAT_EXCHANGE_NOT_FOUND when missing, expired or another user's.
	GetExchange(ctx context.Context, userID, id string) (*ExchangeResponse, error)
}

type chatSyncService struct {
	txRepo       tx.TxRepo
	chatSyncRepo repoChatSync.ChatSyncRepo
}

func NewChatSyncService(txRepo tx.TxRepo,
	chatSyncRepo repoChatSync.ChatSyncRepo) ChatSyncService {
	return &chatSyncService{
		txRepo:       txRepo,
		chatSyncRepo: chatSyncRepo,
	}
}
