package personality_version

import (
	"context"
	"encoding/json"
	"time"

	"befriend/internal/model"
	"befriend/internal/model/enum"
	"befriend/pkg/utils/errors"

	"gorm.io/gorm"
)

// claimDueSQL atomically takes due jobs: pending/failed rows whose retry time has passed, plus running rows
// whose lock expired (a worker died mid-job). SKIP LOCKED lets several workers claim without blocking.
const claimDueSQL = `
UPDATE personality_version
SET status = 'running', locked_until = @locked_until, attempts = attempts + 1, updated_at = @now
WHERE id IN (
	SELECT id FROM personality_version
	WHERE (status IN ('pending', 'failed') AND next_attempt_at <= @now)
	   OR (status = 'running' AND locked_until < @now)
	ORDER BY next_attempt_at
	LIMIT @limit
	FOR UPDATE SKIP LOCKED
)
RETURNING *`

func (r *personalityVersionRepo) Create(ctx context.Context, m *model.PersonalityVersion) (*model.PersonalityVersion, error) {
	if err := r.dbdget.Get(ctx).Create(m).Error; err != nil {
		return nil, err
	}
	return m, nil
}

func (r *personalityVersionRepo) GetByID(ctx context.Context, id string) (*model.PersonalityVersion, error) {
	m := &model.PersonalityVersion{}
	q := r.dbdget.Get(ctx).Where("id = ?", id).Take(m)
	if q.Error != nil {
		if q.Error == gorm.ErrRecordNotFound {
			return nil, errors.From("DATA_NOT_FOUND")
		}
		return nil, q.Error
	}
	return m, nil
}

func (r *personalityVersionRepo) GetLatestByFriend(ctx context.Context, friendID string) (*model.PersonalityVersion, error) {
	m := &model.PersonalityVersion{}
	q := r.dbdget.Get(ctx).Where("friend_id = ? AND status <> ?", friendID, enum.PERSONALITY_ABANDONED).Order("version DESC").Take(m)
	if q.Error != nil {
		if q.Error == gorm.ErrRecordNotFound {
			return nil, errors.From("DATA_NOT_FOUND")
		}
		return nil, q.Error
	}
	return m, nil
}

func (r *personalityVersionRepo) NextVersion(ctx context.Context, friendID string) (int, error) {
	// Two picks (or a pick and the weekly evolution) must not both take the same number: hold a per-friend lock
	// until the caller's transaction ends.
	if err := r.dbdget.Get(ctx).Exec(`SELECT pg_advisory_xact_lock(hashtext(?))`, "personality_version:"+friendID).Error; err != nil {
		return 0, err
	}
	var next int
	err := r.dbdget.Get(ctx).Raw(`SELECT COALESCE(MAX(version), 0) + 1 FROM personality_version WHERE friend_id = ?`, friendID).
		Scan(&next).Error
	return next, err
}

// activeReskin is a reskin that may still run: queued, running, or failed and waiting to retry.
func (r *personalityVersionRepo) activeReskin(ctx context.Context, friendID string) *gorm.DB {
	return r.dbdget.Get(ctx).Model(&model.PersonalityVersion{}).
		Where("friend_id = ? AND reason = ? AND status IN ?", friendID, enum.REASON_RESKIN,
			[]enum.PersonalityStatus{enum.PERSONALITY_PENDING, enum.PERSONALITY_RUNNING, enum.PERSONALITY_FAILED})
}

func (r *personalityVersionRepo) GetActiveReskin(ctx context.Context, friendID string) (*model.PersonalityVersion, error) {
	var jobs []model.PersonalityVersion
	if err := r.activeReskin(ctx, friendID).Order("version DESC").Limit(1).Find(&jobs).Error; err != nil {
		return nil, err
	}
	if len(jobs) == 0 {
		return nil, nil
	}
	return &jobs[0], nil
}

// AbandonReskins ends every active reskin for good; a running one's worker then finds its claim gone.
func (r *personalityVersionRepo) AbandonReskins(ctx context.Context, friendID, reason string, now time.Time) error {
	return r.activeReskin(ctx, friendID).Updates(map[string]interface{}{
		"status": enum.PERSONALITY_ABANDONED, "locked_until": nil, "error": reason, "updated_at": now,
	}).Error
}

func (r *personalityVersionRepo) ClaimDue(ctx context.Context, now time.Time, limit int, lockedUntil time.Time) ([]model.PersonalityVersion, error) {
	var jobs []model.PersonalityVersion
	err := r.dbdget.Get(ctx).
		Raw(claimDueSQL, map[string]interface{}{"now": now, "limit": limit, "locked_until": lockedUntil}).
		Scan(&jobs).Error
	return jobs, err
}

// MarkReady stores the result, but only while the row is still running under this claim.
func (r *personalityVersionRepo) MarkReady(ctx context.Context, claim Claim, llmModel string, vocabularyVersion int, personality, phrasebook json.RawMessage, now time.Time) error {
	q := r.claimed(ctx, claim).
		Updates(map[string]interface{}{
			"status":             enum.PERSONALITY_READY,
			"model":              llmModel,
			"vocabulary_version": vocabularyVersion,
			"personality":        string(personality),
			"phrasebook":         string(phrasebook),
			"error":              nil,
			"locked_until":       nil,
			"updated_at":         now,
		})
	if q.Error != nil {
		return q.Error
	}
	if q.RowsAffected == 0 {
		return errors.From("DATA_CONFLICT").WithDetail("personality version is no longer claimed by this worker")
	}
	return nil
}

// Reschedule releases the claim and sets when to try again. A deferral (budget or rate limit) doesn't
// count as an attempt.
func (r *personalityVersionRepo) Reschedule(ctx context.Context, claim Claim, status enum.PersonalityStatus, nextAttemptAt time.Time, reason string, countAttempt bool, now time.Time) error {
	updates := map[string]interface{}{
		"status":          status,
		"next_attempt_at": nextAttemptAt,
		"locked_until":    nil,
		"error":           reason,
		"updated_at":      now,
	}
	if !countAttempt {
		updates["attempts"] = gorm.Expr("GREATEST(attempts - 1, 0)")
	}
	q := r.claimed(ctx, claim).Updates(updates)
	if q.Error != nil {
		return q.Error
	}
	if q.RowsAffected == 0 {
		return errors.From("DATA_CONFLICT").WithDetail("personality version is no longer claimed by this worker")
	}
	return nil
}

func (r *personalityVersionRepo) claimed(ctx context.Context, claim Claim) *gorm.DB {
	return r.dbdget.Get(ctx).
		Model(&model.PersonalityVersion{}).
		Where("id = ? AND status = ? AND locked_until = ?", claim.ID, enum.PERSONALITY_RUNNING, claim.LockedUntil)
}
