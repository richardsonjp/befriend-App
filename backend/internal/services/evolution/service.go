package evolution

import (
	"context"
	"time"

	"befriend/pkg/utils/logs"
)

const (
	// Interval between a friend's evolutions; the first is a week after it was born, so runs spread over the week.
	Interval = 7 * 24 * time.Hour

	dueBatch = 100
	// processBatch and maxProcessRounds bound one run: generation stops early once the LLM budget defers jobs.
	processBatch     = 5
	maxProcessRounds = 200
)

func (s *evolutionService) Run(ctx context.Context) (*RunSummary, error) {
	summary := &RunSummary{}
	now := time.Now()

	deleted, err := s.triggerEventService.DeleteExpired(ctx, now)
	if err != nil {
		return summary, err
	}
	summary.EventsDeleted = deleted
	if summary.PairingCodesDeleted, err = s.pairingCodeService.DeleteExpired(ctx, now); err != nil {
		return summary, err
	}

	if summary.Queued, err = s.queueDue(ctx, now); err != nil {
		return summary, err
	}

	for round := 0; round < maxProcessRounds && ctx.Err() == nil; round++ {
		n, err := s.personalityService.ProcessDue(ctx, processBatch)
		summary.Generated += n
		if err != nil {
			return summary, err
		}
		if n == 0 {
			break
		}
	}
	return summary, nil
}

// queueDue adds a pending evolution for every due friend and moves its next date on, in one transaction each.
func (s *evolutionService) queueDue(ctx context.Context, now time.Time) (int, error) {
	queued := 0
	for {
		friends, err := s.friendService.ListDueForEvolution(ctx, now, dueBatch)
		if err != nil || len(friends) == 0 {
			return queued, err
		}
		for _, f := range friends {
			err := s.txRepo.Run(ctx, func(ctx context.Context) error {
				version, err := s.personalityVersionService.CreateEvolution(ctx, f.ID)
				if err != nil {
					return err
				}
				if version != nil {
					queued++
				}
				// A friend whose latest version isn't ready yet still moves on, so it isn't re-checked every hour.
				return s.friendService.SetNextEvolutionAt(ctx, f.ID, NextEvolutionAt(f.NextEvolutionAt, now))
			})
			if err != nil {
				logs.Log.Errorf("evolution for friend %s: %v", f.ID, err)
				return queued, err
			}
		}
	}
}

// NextEvolutionAt keeps the friend's weekly rhythm, skipping weeks missed while the job didn't run.
func NextEvolutionAt(due, now time.Time) time.Time {
	next := due.Add(Interval)
	for !next.After(now) {
		next = next.Add(Interval)
	}
	return next
}
