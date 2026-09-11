package llm_budget

import (
	"context"
	"time"

	"befriend/pkg/clients/db"
)

// LLMBudgetRepo counts LLM requests per window (a UTC minute or day) in Postgres, so the worker stays under the
// provider's request caps.
type LLMBudgetRepo interface {
	// Increment adds one request to the window unless it already holds limit; false means the window is full.
	// The upsert locks the window's row, so concurrent workers can't overshoot.
	Increment(ctx context.Context, windowKey string, limit int, expiresAt time.Time) (bool, error)
	DeleteExpired(ctx context.Context, now time.Time) error
}

type llmBudgetRepo struct {
	dbdget db.DBGormDelegate
}

func NewLLMBudgetRepo(dbdget db.DBGormDelegate) LLMBudgetRepo {
	return &llmBudgetRepo{
		dbdget: dbdget,
	}
}
