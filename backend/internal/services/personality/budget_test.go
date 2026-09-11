package personality

import (
	"testing"
	"time"
)

func TestBudgetWindows(t *testing.T) {
	// 23:59:30 in Jakarta is 16:59:30 UTC: windows follow UTC, not the server's zone.
	now := time.Date(2026, 9, 11, 23, 59, 30, 0, time.FixedZone("WIB", 7*3600))
	minuteKey, minuteEnd, dayKey, dayEnd := budgetWindows(now)

	if minuteKey != "minute:202609111659" || !minuteEnd.Equal(time.Date(2026, 9, 11, 17, 0, 0, 0, time.UTC)) {
		t.Errorf("minute window = %s ending %s", minuteKey, minuteEnd)
	}
	if dayKey != "day:20260911" || !dayEnd.Equal(time.Date(2026, 9, 12, 0, 0, 0, 0, time.UTC)) {
		t.Errorf("day window = %s ending %s", dayKey, dayEnd)
	}
}
