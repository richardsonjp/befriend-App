package personality

import (
	"testing"
	"time"

	"befriend/internal/model"
)

func TestActivityLines(t *testing.T) {
	app, seconds := "Xcode", 900
	events := []model.TriggerEvent{
		{Kind: "app_switched", AppName: &app, OccurredAt: time.Date(2026, 9, 7, 16, 40, 0, 0, time.UTC)},
		{Kind: "went_idle", Seconds: &seconds, OccurredAt: time.Date(2026, 9, 7, 17, 5, 0, 0, time.UTC)},
	}
	lines := activityLines(events, "Asia/Jakarta") // UTC+7
	want := []ActivityLine{{Kind: "app_switched", App: "Xcode", At: "Mon 23:40"}, {Kind: "went_idle", Seconds: 900, At: "Tue 00:05"}}
	if len(lines) != 2 || lines[0] != want[0] || lines[1] != want[1] {
		t.Errorf("activityLines = %+v; want %+v", lines, want)
	}
	if got := activityLines(events[:1], "Not/AZone"); got[0].At != "Mon 16:40" {
		t.Errorf("unknown zone should fall back to UTC: %+v", got)
	}
}

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
