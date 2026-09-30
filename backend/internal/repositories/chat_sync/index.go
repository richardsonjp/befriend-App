package chat_sync

import (
	"context"
	"time"

	"befriend/internal/model"
	"befriend/pkg/clients/db"
)

type ChatSyncRepo interface {
	// GetKey returns DATA_NOT_FOUND when the user has no chat sync key yet.
	GetKey(ctx context.Context, userID string) (*model.ChatSyncKey, error)
	// CreateKeyIfAbsent stores the key id unless the user already has one.
	CreateKeyIfAbsent(ctx context.Context, userID, keyID string) error

	// PutRecord writes the record unless the stored one has a later modified_at, giving it a new seq. It returns
	// the record's current seq and whether this write was applied.
	PutRecord(ctx context.Context, m *model.ChatRecord) (int64, bool, error)
	// ListRecordsAfter returns up to limit of the user's records with seq > after, by seq.
	ListRecordsAfter(ctx context.Context, userID string, after int64, limit int) ([]model.ChatRecord, error)

	// DeleteExpiredExchange removes the exchange if it expired, whoever it belongs to.
	DeleteExpiredExchange(ctx context.Context, id string, now time.Time) error
	CreateExchangeIfAbsent(ctx context.Context, m *model.ChatKeyExchange) error
	// GetExchange locks the row when forUpdate is set (call inside a transaction). DATA_NOT_FOUND when missing.
	GetExchange(ctx context.Context, id string, forUpdate bool) (*model.ChatKeyExchange, error)
	UpdateExchange(ctx context.Context, m *model.ChatKeyExchange) error
}

type chatSyncRepo struct {
	dbdget db.DBGormDelegate
}

func NewChatSyncRepo(dbdget db.DBGormDelegate) ChatSyncRepo {
	return &chatSyncRepo{
		dbdget: dbdget,
	}
}
