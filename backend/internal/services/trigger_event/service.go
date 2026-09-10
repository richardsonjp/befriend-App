package trigger_event

import (
	"context"
	"strings"
	"time"
	"unicode/utf8"

	"befriend/internal/model"
	"befriend/pkg/utils/errors"
	customStr "befriend/pkg/utils/strings"
	"befriend/pkg/utils/vocabulary"
)

const (
	// Retention is how long events are kept (the weekly evolution reads the last 300).
	Retention = 30 * 24 * time.Hour
	// MaxAppNameLength matches trigger_event.app_name.
	MaxAppNameLength = 40
	// Devices queue events offline; ones stamped in the future beyond this skew are dropped.
	maxClockSkew = 5 * time.Minute
)

func (s *triggerEventService) Record(ctx context.Context, payload RecordPayload) (*RecordResponse, error) {
	owner, err := s.userService.GetUserByID(ctx, payload.UserID)
	if err != nil {
		return nil, err
	}
	if owner.LogSyncPaused {
		return &RecordResponse{}, nil
	}
	events, err := buildEvents(payload, owner.ExcludedApps.Data, time.Now())
	if err != nil {
		return nil, err
	}
	accepted, err := s.triggerEventRepo.InsertNew(ctx, events)
	if err != nil {
		return nil, err
	}
	return &RecordResponse{Accepted: int(accepted)}, nil
}

func (s *triggerEventService) DeleteAll(ctx context.Context, userID string) error {
	return s.triggerEventRepo.DeleteByUser(ctx, userID)
}

func (s *triggerEventService) DeleteByApps(ctx context.Context, userID string, appNames []string) error {
	lower := make([]string, 0, len(appNames))
	for _, name := range appNames {
		lower = append(lower, strings.ToLower(name))
	}
	return s.triggerEventRepo.DeleteByApps(ctx, userID, lower)
}

// buildEvents turns an upload into rows: unknown kinds are rejected; events for excluded apps, stamped in the
// future or older than the retention window are dropped. App names are kept only for app_switched.
func buildEvents(payload RecordPayload, excludedApps []string, now time.Time) ([]model.TriggerEvent, error) {
	excluded := make(map[string]bool, len(excludedApps))
	for _, name := range excludedApps {
		excluded[strings.ToLower(name)] = true
	}

	var deviceID *string
	if payload.DeviceID != "" {
		deviceID = &payload.DeviceID
	}
	events := make([]model.TriggerEvent, 0, len(payload.Events))
	for _, e := range payload.Events {
		if !vocabulary.IsTriggerKind(e.Kind) {
			return nil, errors.From("VALIDATION_FAILED").WithDetail("unknown trigger kind " + e.Kind)
		}
		if e.OccurredAt.After(now.Add(maxClockSkew)) || e.OccurredAt.Before(now.Add(-Retention)) {
			continue
		}

		var appName *string
		if e.Kind == "app_switched" && e.AppName != nil {
			if name := CleanAppName(*e.AppName); name != "" {
				if excluded[strings.ToLower(name)] {
					continue
				}
				appName = &name
			}
		}
		events = append(events, model.TriggerEvent{
			UserID:        payload.UserID,
			DeviceID:      deviceID,
			ClientEventID: strings.ToLower(e.ClientEventID),
			Kind:          e.Kind,
			AppName:       appName,
			Seconds:       e.Seconds,
			OccurredAt:    e.OccurredAt,
		})
	}
	return events, nil
}

// CleanAppName drops invisible characters, flattens whitespace and caps the length. App names reach the LLM
// prompt, so they must be one plain line.
func CleanAppName(name string) string {
	name = strings.Map(func(r rune) rune {
		if customStr.IsHiddenRune(r) {
			return -1
		}
		return r
	}, name)
	name = strings.Join(strings.Fields(name), " ")
	if utf8.RuneCountInString(name) > MaxAppNameLength {
		name = string([]rune(name)[:MaxAppNameLength])
	}
	return strings.TrimSpace(name)
}
