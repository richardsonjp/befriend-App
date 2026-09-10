package personality

import (
	"testing"
	"time"
)

func TestRetryDelay(t *testing.T) {
	tests := []struct {
		attempts int
		want     time.Duration
	}{
		{0, 5 * time.Minute}, // defensive: a claim always counts at least one attempt
		{1, 5 * time.Minute},
		{2, 30 * time.Minute},
		{3, 2 * time.Hour},
		{4, 12 * time.Hour},
		{50, 12 * time.Hour},
	}
	for _, tt := range tests {
		if got := retryDelay(tt.attempts); got != tt.want {
			t.Errorf("retryDelay(%d) = %s; want %s", tt.attempts, got, tt.want)
		}
	}
}
