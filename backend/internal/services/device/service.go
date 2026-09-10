package device

import (
	"context"
	"strings"
	"time"

	"befriend/internal/model"
	"befriend/internal/model/enum"
	"befriend/pkg/utils/errors"
)

// ponytail: one device row per sign-in; reuse rows via a client-sent device_id if they pile up.
func (s *deviceService) Create(ctx context.Context, payload CreatePayload) (*model.Device, error) {
	return s.deviceRepo.Create(ctx, &model.Device{
		UserID:   payload.UserID,
		Platform: enum.NewDevicePlatform(payload.Platform),
		Name:     payload.Name,
	})
}

// UpdatePushTokens stores whichever tokens the payload carries. A Live Activity update token is only usable
// for that activity's 8-hour life, so it's stored with the activity's start time.
func (s *deviceService) UpdatePushTokens(ctx context.Context, payload PushTokensPayload) error {
	now := time.Now()
	fields := map[string]interface{}{"apns_env": payload.APNsEnv, "last_seen_at": now, "updated_at": now}
	if err := setToken(fields, "la_push_to_start_token", payload.LAPushToStartToken); err != nil {
		return err
	}
	if err := setToken(fields, "widget_push_token", payload.WidgetPushToken); err != nil {
		return err
	}
	if payload.LAPushToken != nil {
		if err := setToken(fields, "la_push_token", payload.LAPushToken); err != nil {
			return err
		}
		switch {
		case *payload.LAPushToken == "":
			fields["la_started_at"] = nil
		case payload.LAStartedAt == nil:
			return errors.From("VALIDATION_FAILED").WithDetail("la_started_at is required with la_push_token")
		default:
			fields["la_started_at"] = *payload.LAStartedAt
		}
	}
	return s.deviceRepo.UpdatePushTokens(ctx, payload.DeviceID, payload.UserID, fields)
}

// setToken adds a token column to fields: nil leaves it out, "" clears it, anything else must be hex.
// (Checked here rather than with a validate tag: omitempty doesn't skip a pointer to "".)
func setToken(fields map[string]interface{}, column string, token *string) error {
	switch {
	case token == nil:
	case *token == "":
		fields[column] = nil
	case !isHex(*token):
		return errors.From("VALIDATION_FAILED").WithDetail(column + " must be hexadecimal")
	default:
		fields[column] = strings.ToLower(*token)
	}
	return nil
}

func isHex(s string) bool {
	for _, r := range s {
		if !strings.ContainsRune("0123456789abcdefABCDEF", r) {
			return false
		}
	}
	return true
}
