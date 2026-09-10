package evolution

import (
	"testing"
	"time"
)

func TestNextEvolutionAt(t *testing.T) {
	now := time.Date(2026, 9, 11, 10, 0, 0, 0, time.UTC)
	tests := []struct {
		name string
		due  time.Time
		want time.Time
	}{
		{"due just now", now.Add(-time.Minute), now.Add(-time.Minute).Add(Interval)},
		{"due exactly now", now, now.Add(Interval)},
		{"missed three weeks keeps the weekday and time", now.Add(-3*Interval - time.Hour), now.Add(Interval - time.Hour)},
	}
	for _, tt := range tests {
		got := NextEvolutionAt(tt.due, now)
		if !got.Equal(tt.want) {
			t.Errorf("%s: got %s; want %s", tt.name, got, tt.want)
		}
		if !got.After(now) {
			t.Errorf("%s: next evolution %s is not in the future", tt.name, got)
		}
	}
}
