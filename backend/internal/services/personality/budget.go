package personality

import (
	"context"
	stderrors "errors"
	"time"
)

var errBudgetFull = stderrors.New("llm request budget full")

// budgetWindows names the UTC minute and day a request counts against, with the end of each.
func budgetWindows(now time.Time) (minuteKey string, minuteEnd time.Time, dayKey string, dayEnd time.Time) {
	now = now.UTC()
	minuteStart := now.Truncate(time.Minute)
	dayStart := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)
	return "minute:" + minuteStart.Format("200601021504"), minuteStart.Add(time.Minute),
		"day:" + dayStart.Format("20060102"), dayStart.Add(24 * time.Hour)
}

// consumeBudget reserves one LLM request in the current UTC minute and day, both or neither (one transaction).
// When a cap is reached it reserves nothing and returns when that window reopens.
func (s *personalityService) consumeBudget(ctx context.Context, now time.Time, minuteCap, dailyCap int) (bool, time.Time, error) {
	minuteKey, minuteEnd, dayKey, dayEnd := budgetWindows(now)
	var retryAt time.Time
	err := s.txRepo.Run(ctx, func(ctx context.Context) error {
		if err := s.llmBudgetRepo.DeleteExpired(ctx, now); err != nil {
			return err
		}
		ok, err := s.llmBudgetRepo.Increment(ctx, dayKey, dailyCap, dayEnd)
		if err != nil {
			return err
		}
		if !ok {
			retryAt = dayEnd
			return errBudgetFull
		}
		ok, err = s.llmBudgetRepo.Increment(ctx, minuteKey, minuteCap, minuteEnd)
		if err != nil {
			return err
		}
		if !ok {
			retryAt = minuteEnd
			return errBudgetFull // rolls back the day's increment
		}
		return nil
	})
	if stderrors.Is(err, errBudgetFull) {
		return false, retryAt, nil
	}
	return err == nil, time.Time{}, err
}
