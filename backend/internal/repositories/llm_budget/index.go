package llm_budget

import (
	"context"
	"time"

	"befriend/pkg/clients/redis"
)

// LLMBudgetRepo counts LLM requests per minute and per UTC day in Redis, so the worker stays under the
// provider's request caps.
type LLMBudgetRepo interface {
	// TryConsume reserves one request in the current minute and day. When a cap is reached it reserves
	// nothing and returns when the next window opens.
	TryConsume(ctx context.Context, now time.Time, minuteCap, dailyCap int) (ok bool, retryAt time.Time, err error)
}

type llmBudgetRepo struct {
	redis redis.RedisDelegate
}

func NewLLMBudgetRepo(redis redis.RedisDelegate) LLMBudgetRepo {
	return &llmBudgetRepo{
		redis: redis,
	}
}
