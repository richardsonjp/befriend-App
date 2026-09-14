package user_application

import (
	"context"
	"strings"

	"befriend/internal/model"
	ct "befriend/internal/model/custom_type"
	"befriend/internal/services/trigger_event"
)

const maxExcludedApps = 100

type SettingsResponse struct {
	LogSyncPaused bool     `json:"log_sync_paused"`
	ExcludedApps  []string `json:"excluded_apps"`
	SkinID        *string  `json:"skin_id"` // null = the built-in skin
}

// UpdateSettingsPayload changes only the fields present. SkinID "" picks the built-in skin.
type UpdateSettingsPayload struct {
	LogSyncPaused *bool     `json:"log_sync_paused"`
	ExcludedApps  *[]string `json:"excluded_apps" validate:"omitempty,max=100,dive,max=200"`
	SkinID        *string   `json:"skin_id" validate:"omitempty,max=40"`
}

func (s *userApplicationService) GetSettings(ctx context.Context, userID string) (*SettingsResponse, error) {
	owner, err := s.userService.GetUserByID(ctx, userID)
	if err != nil {
		return nil, err
	}
	return toSettings(owner), nil
}

// UpdateSettings saves the sync settings and skin pick. Excluding an app also deletes the events already stored
// for it; picking another skin tells the account's other devices once the change commits.
func (s *userApplicationService) UpdateSettings(ctx context.Context, userID string, payload UpdateSettingsPayload) (*SettingsResponse, error) {
	var response *SettingsResponse
	err := s.txRepo.Run(ctx, func(ctx context.Context) error {
		owner, err := s.userService.GetUserByID(ctx, userID)
		if err != nil {
			return err
		}
		if payload.LogSyncPaused != nil {
			owner.LogSyncPaused = *payload.LogSyncPaused
		}
		if payload.ExcludedApps != nil {
			apps := normalizeApps(*payload.ExcludedApps)
			owner.ExcludedApps = ct.JSONB[[]string]{Data: apps}
			if err := s.triggerEventService.DeleteByApps(ctx, userID, apps); err != nil {
				return err
			}
		}
		if err := s.userService.UpdateSyncSettings(ctx, *owner); err != nil {
			return err
		}
		if payload.SkinID != nil {
			if err := s.updateSkin(ctx, owner, *payload.SkinID); err != nil {
				return err
			}
		}
		response = toSettings(owner)
		return nil
	})
	if err != nil {
		return nil, err
	}
	return response, nil
}

func (s *userApplicationService) updateSkin(ctx context.Context, owner *model.User, skinID string) error {
	var next *string
	if skinID != "" {
		next = &skinID
	}
	if sameSkin(owner.SkinID, next) {
		return nil
	}
	if err := s.userService.UpdateSkin(ctx, owner.ID, next); err != nil {
		return err
	}
	owner.SkinID = next
	return s.skinService.NotifyUser(ctx, owner.ID)
}

func sameSkin(a, b *string) bool {
	return (a == nil && b == nil) || (a != nil && b != nil && *a == *b)
}

// normalizeApps cleans names the way stored events are cleaned and drops case-insensitive duplicates.
func normalizeApps(names []string) []string {
	seen := map[string]bool{}
	apps := []string{}
	for _, name := range names {
		name = trigger_event.CleanAppName(name)
		key := strings.ToLower(name)
		if name == "" || seen[key] || len(apps) == maxExcludedApps {
			continue
		}
		seen[key] = true
		apps = append(apps, name)
	}
	return apps
}

func toSettings(owner *model.User) *SettingsResponse {
	apps := owner.ExcludedApps.Data
	if apps == nil {
		apps = []string{}
	}
	return &SettingsResponse{LogSyncPaused: owner.LogSyncPaused, ExcludedApps: apps, SkinID: owner.SkinID}
}
