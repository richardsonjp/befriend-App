package chat_sync

import (
	"context"
	"time"

	"befriend/internal/model"
	"befriend/pkg/utils/errors"
)

const (
	// MaxBlobSize caps one record's ciphertext (2 MiB decoded; about 2.8 MB as base64, under Fiber's 4 MB body limit).
	MaxBlobSize      = 2 << 20
	DefaultPullLimit = 100
	ExchangeTTL      = 15 * time.Minute
	// modifiedAtLayout keeps a fixed width so clients parse it with one format.
	modifiedAtLayout = "2006-01-02T15:04:05.000000Z07:00"
)

func (s *chatSyncService) GetKey(ctx context.Context, userID string) (*KeyResponse, error) {
	m, err := s.chatSyncRepo.GetKey(ctx, userID)
	if errors.Is(err, "DATA_NOT_FOUND") {
		return &KeyResponse{}, nil
	}
	if err != nil {
		return nil, err
	}
	return &KeyResponse{KeyID: &m.KeyID}, nil
}

func (s *chatSyncService) SetKey(ctx context.Context, payload KeyPayload) (*KeyResponse, error) {
	// ponytail: insert-then-read is race-free because a stored key id never changes.
	if err := s.chatSyncRepo.CreateKeyIfAbsent(ctx, payload.UserID, payload.KeyID); err != nil {
		return nil, err
	}
	m, err := s.chatSyncRepo.GetKey(ctx, payload.UserID)
	if err != nil {
		return nil, err
	}
	if m.KeyID != payload.KeyID {
		return nil, errors.From("CHAT_KEY_MISMATCH")
	}
	return &KeyResponse{KeyID: &m.KeyID}, nil
}

func (s *chatSyncService) PutRecord(ctx context.Context, payload RecordPayload) (*PutRecordResponse, error) {
	record, err := buildRecord(payload)
	if err != nil {
		return nil, err
	}
	seq, applied, err := s.chatSyncRepo.PutRecord(ctx, record)
	if err != nil {
		return nil, err
	}
	return &PutRecordResponse{Seq: seq, Applied: applied}, nil
}

func (s *chatSyncService) ListRecords(ctx context.Context, payload ListRecordsPayload) (*ListRecordsResponse, error) {
	limit := payload.Limit
	if limit == 0 {
		limit = DefaultPullLimit
	}
	// One extra row tells whether there's another page.
	records, err := s.chatSyncRepo.ListRecordsAfter(ctx, payload.UserID, payload.After, limit+1)
	if err != nil {
		return nil, err
	}
	return buildPage(records, payload.After, limit), nil
}

func (s *chatSyncService) PutExchange(ctx context.Context, payload ExchangePayload) (*ExchangeResponse, error) {
	var result *model.ChatKeyExchange
	err := s.txRepo.Run(ctx, func(ctx context.Context) error {
		now := time.Now()
		if err := s.chatSyncRepo.DeleteExpiredExchange(ctx, payload.ID, now); err != nil {
			return err
		}
		err := s.chatSyncRepo.CreateExchangeIfAbsent(ctx, &model.ChatKeyExchange{
			ID:        payload.ID,
			UserID:    payload.UserID,
			ExpiresAt: now.Add(ExchangeTTL),
		})
		if err != nil {
			return err
		}
		stored, err := s.chatSyncRepo.GetExchange(ctx, payload.ID, true)
		if err != nil {
			return err
		}
		if stored.UserID != payload.UserID {
			return errors.From("CHAT_EXCHANGE_NOT_FOUND")
		}
		merged, changed, err := mergeExchange(*stored, payload)
		if err != nil {
			return err
		}
		if changed {
			if err := s.chatSyncRepo.UpdateExchange(ctx, &merged); err != nil {
				return err
			}
		}
		result = &merged
		return nil
	})
	if err != nil {
		return nil, err
	}
	return exchangeResponse(result), nil
}

func (s *chatSyncService) GetExchange(ctx context.Context, userID, id string) (*ExchangeResponse, error) {
	m, err := s.chatSyncRepo.GetExchange(ctx, id, false)
	if errors.Is(err, "DATA_NOT_FOUND") {
		return nil, errors.From("CHAT_EXCHANGE_NOT_FOUND")
	}
	if err != nil {
		return nil, err
	}
	if m.UserID != userID || !time.Now().Before(m.ExpiresAt) {
		return nil, errors.From("CHAT_EXCHANGE_NOT_FOUND")
	}
	return exchangeResponse(m), nil
}

// buildRecord checks a write and turns it into a row. A deletion stores a tombstone: no blob, size 0.
func buildRecord(payload RecordPayload) (*model.ChatRecord, error) {
	m := &model.ChatRecord{
		UserID:   payload.UserID,
		Kind:     payload.Kind,
		RecordID: payload.ID,
		// Postgres keeps microseconds: truncate here so a resent write compares equal to what's stored.
		ModifiedAt: payload.ModifiedAt.UTC().Truncate(time.Microsecond),
		Deleted:    payload.Deleted,
	}
	if payload.Deleted {
		return m, nil
	}
	if len(payload.Blob) == 0 {
		return nil, errors.From("VALIDATION_FAILED").WithDetail("blob is required unless deleted")
	}
	if len(payload.Blob) > MaxBlobSize {
		return nil, errors.From("CHAT_RECORD_TOO_LARGE")
	}
	m.Blob = payload.Blob
	m.Size = len(payload.Blob)
	return m, nil
}

// buildPage turns up to limit+1 rows (by seq) into a page; the extra row only signals "more".
func buildPage(records []model.ChatRecord, after int64, limit int) *ListRecordsResponse {
	more := len(records) > limit
	if more {
		records = records[:limit]
	}
	page := &ListRecordsResponse{Records: make([]RecordResponse, 0, len(records)), Next: after, More: more}
	for _, r := range records {
		item := RecordResponse{
			Kind:       r.Kind,
			ID:         r.RecordID,
			Seq:        r.Seq,
			ModifiedAt: r.ModifiedAt.UTC().Format(modifiedAtLayout),
			Deleted:    r.Deleted,
		}
		if !r.Deleted {
			item.Blob = r.Blob
		}
		page.Records = append(page.Records, item)
		if r.Seq > page.Next {
			page.Next = r.Seq
		}
	}
	return page
}

// mergeExchange fills in the fields the payload sets. A filled field may be resent unchanged but never replaced.
func mergeExchange(stored model.ChatKeyExchange, payload ExchangePayload) (model.ChatKeyExchange, bool, error) {
	merged := stored
	changed := false
	fields := []struct {
		dst      **string
		incoming string
	}{
		{&merged.MacPublic, payload.MacPublic},
		{&merged.PhonePublic, payload.PhonePublic},
		{&merged.SealedForMac, payload.SealedForMac},
		{&merged.SealedForPhone, payload.SealedForPhone},
	}
	for _, f := range fields {
		if f.incoming == "" {
			continue
		}
		current := *f.dst
		if current != nil && *current != "" {
			if *current != f.incoming {
				return stored, false, errors.From("CHAT_EXCHANGE_CONFLICT")
			}
			continue
		}
		value := f.incoming
		*f.dst = &value
		changed = true
	}
	return merged, changed, nil
}

func exchangeResponse(m *model.ChatKeyExchange) *ExchangeResponse {
	return &ExchangeResponse{
		MacPublic:      m.MacPublic,
		PhonePublic:    m.PhonePublic,
		SealedForMac:   m.SealedForMac,
		SealedForPhone: m.SealedForPhone,
	}
}
