package trigger_event

import (
	"strings"
	"testing"
	"time"
)

func TestBuildEvents(t *testing.T) {
	now := time.Date(2026, 9, 11, 10, 0, 0, 0, time.UTC)
	name := func(s string) *string { return &s }
	seconds := 300
	payload := RecordPayload{
		UserID:   "user-1",
		DeviceID: "device-1",
		Events: []EventPayload{
			{ClientEventID: "A1B2C3D4-0000-4000-8000-000000000001", Kind: "app_switched", AppName: name("  Xcode\u200b "), OccurredAt: now.Add(-time.Minute)},
			{ClientEventID: "00000000-0000-4000-8000-000000000002", Kind: "app_switched", AppName: name("Secret Diary"), OccurredAt: now},
			{ClientEventID: "00000000-0000-4000-8000-000000000003", Kind: "went_idle", AppName: name("ignored"), Seconds: &seconds, OccurredAt: now},
			{ClientEventID: "00000000-0000-4000-8000-000000000004", Kind: "returned", OccurredAt: now.Add(time.Hour)},         // future
			{ClientEventID: "00000000-0000-4000-8000-000000000005", Kind: "poked", OccurredAt: now.Add(-31 * 24 * time.Hour)}, // too old
			{ClientEventID: "00000000-0000-4000-8000-000000000006", Kind: "app_switched", AppName: name(strings.Repeat("x", 60)), OccurredAt: now},
		},
	}

	events, err := buildEvents(payload, []string{"secret diary"}, now)
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 3 {
		t.Fatalf("got %d events; want 3 (excluded, future and too old dropped)", len(events))
	}
	if *events[0].AppName != "Xcode" || events[0].ClientEventID != "a1b2c3d4-0000-4000-8000-000000000001" || *events[0].DeviceID != "device-1" {
		t.Errorf("first event = %+v", events[0])
	}
	if events[1].AppName != nil || *events[1].Seconds != 300 {
		t.Errorf("went_idle keeps seconds but no app name: %+v", events[1])
	}
	if len([]rune(*events[2].AppName)) != MaxAppNameLength {
		t.Errorf("app name not capped: %q", *events[2].AppName)
	}

	payload.Events = []EventPayload{{ClientEventID: "00000000-0000-4000-8000-000000000007", Kind: "exploded", OccurredAt: now}}
	if _, err := buildEvents(payload, nil, now); err == nil {
		t.Error("unknown kind accepted")
	}
}
