package llm_budget

import (
	"context"
	"time"

	"befriend/pkg/utils/logs"

	goredis "github.com/go-redis/redis"
)

// ponytail: INCR-then-check isn't atomic across counters; fine for one worker loop per instance. Use a Lua
// script if several instances share the budget.
func (r *llmBudgetRepo) TryConsume(ctx context.Context, now time.Time, minuteCap, dailyCap int) (bool, time.Time, error) {
	client := r.redis.Use()
	now = now.UTC()
	dayKey := "llm:day:" + now.Format("20060102")
	minuteKey := "llm:min:" + now.Format("200601021504")

	day, err := incrWithTTL(client, dayKey, 25*time.Hour)
	if err != nil {
		return false, time.Time{}, err
	}
	if day > int64(dailyCap) {
		release(client, dayKey)
		return false, now.Truncate(24 * time.Hour).Add(24 * time.Hour), nil
	}

	minute, err := incrWithTTL(client, minuteKey, 2*time.Minute)
	if err != nil {
		release(client, dayKey)
		return false, time.Time{}, err
	}
	if minute > int64(minuteCap) {
		release(client, minuteKey, dayKey)
		return false, now.Truncate(time.Minute).Add(time.Minute), nil
	}
	return true, time.Time{}, nil
}

func incrWithTTL(client *goredis.Client, key string, ttl time.Duration) (int64, error) {
	n, err := client.Incr(key).Result()
	if err != nil {
		return 0, err
	}
	if n == 1 {
		if err := client.Expire(key, ttl).Err(); err != nil {
			logs.Log.Errorf("llm budget: expire %s: %v", key, err)
		}
	}
	return n, nil
}

// release undoes a reservation; if that fails the window's cap trips one request early until it rolls over.
func release(client *goredis.Client, keys ...string) {
	for _, key := range keys {
		if err := client.Decr(key).Err(); err != nil {
			logs.Log.Errorf("llm budget: release %s: %v", key, err)
		}
	}
}
