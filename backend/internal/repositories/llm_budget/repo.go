package llm_budget

import (
	"context"
	"time"
)

// incrementSQL returns a row only when the request was counted: a full window matches no row to update.
const incrementSQL = `
INSERT INTO llm_request_budget (window_key, used, expires_at) VALUES (@window_key, 1, @expires_at)
ON CONFLICT (window_key) DO UPDATE SET used = llm_request_budget.used + 1
WHERE llm_request_budget.used < @limit
RETURNING used`

func (r *llmBudgetRepo) Increment(ctx context.Context, windowKey string, limit int, expiresAt time.Time) (bool, error) {
	if limit <= 0 {
		return false, nil
	}
	var used []int
	err := r.dbdget.Get(ctx).
		Raw(incrementSQL, map[string]interface{}{"window_key": windowKey, "expires_at": expiresAt, "limit": limit}).
		Scan(&used).Error
	return err == nil && len(used) == 1, err
}

func (r *llmBudgetRepo) DeleteExpired(ctx context.Context, now time.Time) error {
	return r.dbdget.Get(ctx).Exec(`DELETE FROM llm_request_budget WHERE expires_at <= ?`, now).Error
}
