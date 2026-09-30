package chat_sync

import (
	"context"
	"time"

	"befriend/internal/model"
	"befriend/pkg/utils/errors"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

func (r *chatSyncRepo) GetKey(ctx context.Context, userID string) (*model.ChatSyncKey, error) {
	m := &model.ChatSyncKey{}
	if err := r.dbdget.Get(ctx).Where("user_id = ?", userID).Take(m).Error; err != nil {
		if err == gorm.ErrRecordNotFound {
			return nil, errors.From("DATA_NOT_FOUND")
		}
		return nil, err
	}
	return m, nil
}

func (r *chatSyncRepo) CreateKeyIfAbsent(ctx context.Context, userID, keyID string) error {
	return r.dbdget.Get(ctx).
		Clauses(clause.OnConflict{Columns: []clause.Column{{Name: "user_id"}}, DoNothing: true}).
		Create(&model.ChatSyncKey{UserID: userID, KeyID: keyID}).Error
}

// putRecordSQL is last-writer-wins in one statement, so concurrent writes of the same record can't interleave.
// A skipped write still burns a seq value; gaps are fine.
const putRecordSQL = `
INSERT INTO chat_records AS r (user_id, kind, record_id, seq, modified_at, deleted, blob, size)
VALUES (?, ?, ?, nextval('chat_records_seq'), ?, ?, ?, ?)
ON CONFLICT (user_id, kind, record_id) DO UPDATE
SET seq = EXCLUDED.seq, modified_at = EXCLUDED.modified_at, deleted = EXCLUDED.deleted,
    blob = EXCLUDED.blob, size = EXCLUDED.size, updated_at = NOW()
WHERE r.modified_at <= EXCLUDED.modified_at
RETURNING seq`

func (r *chatSyncRepo) PutRecord(ctx context.Context, m *model.ChatRecord) (int64, bool, error) {
	var seqs []int64
	err := r.dbdget.Get(ctx).
		Raw(putRecordSQL, m.UserID, m.Kind, m.RecordID, m.ModifiedAt, m.Deleted, m.Blob, m.Size).
		Scan(&seqs).Error
	if err != nil {
		return 0, false, err
	}
	if len(seqs) == 1 {
		return seqs[0], true, nil
	}

	// A newer version is stored: report its seq.
	var current []int64
	err = r.dbdget.Get(ctx).
		Model(&model.ChatRecord{}).
		Where("user_id = ? AND kind = ? AND record_id = ?", m.UserID, m.Kind, m.RecordID).
		Pluck("seq", &current).Error
	if err != nil {
		return 0, false, err
	}
	if len(current) == 0 {
		return 0, false, errors.From("INTERNAL_SERVER_ERROR")
	}
	return current[0], false, nil
}

func (r *chatSyncRepo) ListRecordsAfter(ctx context.Context, userID string, after int64, limit int) ([]model.ChatRecord, error) {
	var records []model.ChatRecord
	err := r.dbdget.Get(ctx).
		Where("user_id = ? AND seq > ?", userID, after).
		Order("seq ASC").
		Limit(limit).
		Find(&records).Error
	return records, err
}

func (r *chatSyncRepo) DeleteExpiredExchange(ctx context.Context, id string, now time.Time) error {
	return r.dbdget.Get(ctx).Where("id = ? AND expires_at <= ?", id, now).Delete(&model.ChatKeyExchange{}).Error
}

func (r *chatSyncRepo) CreateExchangeIfAbsent(ctx context.Context, m *model.ChatKeyExchange) error {
	return r.dbdget.Get(ctx).
		Clauses(clause.OnConflict{Columns: []clause.Column{{Name: "id"}}, DoNothing: true}).
		Create(m).Error
}

func (r *chatSyncRepo) GetExchange(ctx context.Context, id string, forUpdate bool) (*model.ChatKeyExchange, error) {
	q := r.dbdget.Get(ctx)
	if forUpdate {
		q = q.Clauses(clause.Locking{Strength: "UPDATE"})
	}
	m := &model.ChatKeyExchange{}
	if err := q.Where("id = ?", id).Take(m).Error; err != nil {
		if err == gorm.ErrRecordNotFound {
			return nil, errors.From("DATA_NOT_FOUND")
		}
		return nil, err
	}
	return m, nil
}

func (r *chatSyncRepo) UpdateExchange(ctx context.Context, m *model.ChatKeyExchange) error {
	return r.dbdget.Get(ctx).
		Model(&model.ChatKeyExchange{}).
		Where("id = ?", m.ID).
		Updates(map[string]interface{}{
			"mac_public":       m.MacPublic,
			"phone_public":     m.PhonePublic,
			"sealed_for_mac":   m.SealedForMac,
			"sealed_for_phone": m.SealedForPhone,
		}).Error
}
