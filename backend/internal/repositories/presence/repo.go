package presence

import (
	"context"
	"time"

	"befriend/internal/model"
	"befriend/pkg/utils/errors"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

const listDueSQL = `
SELECT user_id FROM presence
WHERE (owner = 'mac' AND (NOT mac_active OR mac_seen_at IS NULL OR mac_seen_at < @mac_seen_after OR phone_claim_until > @now))
   OR (owner = 'phone' AND mac_active AND mac_seen_at >= @mac_seen_after AND (phone_claim_until IS NULL OR phone_claim_until <= @now))
   OR (changed_at > COALESCE(last_push_at, 'epoch'::timestamptz) AND COALESCE(last_push_at, 'epoch'::timestamptz) <= @pushed_before)
LIMIT @limit`

func (r *presenceRepo) GetForUpdate(ctx context.Context, userID string) (*model.Presence, error) {
	db := r.dbdget.Get(ctx)
	lock := func() (*model.Presence, error) {
		m := &model.Presence{}
		return m, db.Clauses(clause.Locking{Strength: "UPDATE"}).Where("user_id = ?", userID).Take(m).Error
	}
	m, err := lock()
	if err != gorm.ErrRecordNotFound {
		return m, err
	}
	// First change for this user: create the row (a concurrent first change may win the insert).
	if err := db.Exec(`INSERT INTO presence (user_id) VALUES (?) ON CONFLICT (user_id) DO NOTHING`, userID).Error; err != nil {
		return nil, err
	}
	return lock()
}

func (r *presenceRepo) Get(ctx context.Context, userID string) (*model.Presence, error) {
	m := &model.Presence{}
	if err := r.dbdget.Get(ctx).Where("user_id = ?", userID).Take(m).Error; err != nil {
		if err == gorm.ErrRecordNotFound {
			return nil, errors.From("DATA_NOT_FOUND")
		}
		return nil, err
	}
	return m, nil
}

func (r *presenceRepo) Save(ctx context.Context, m *model.Presence) error {
	return r.dbdget.Get(ctx).Save(m).Error
}

func (r *presenceRepo) ListDue(ctx context.Context, now, macSeenAfter, pushedBefore time.Time, limit int) ([]string, error) {
	var userIDs []string
	err := r.dbdget.Get(ctx).
		Raw(listDueSQL, map[string]interface{}{"now": now, "mac_seen_after": macSeenAfter, "pushed_before": pushedBefore, "limit": limit}).
		Scan(&userIDs).Error
	return userIDs, err
}
