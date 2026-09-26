package user_application

import (
	"context"
	"strings"

	"befriend/internal/model"
	ct "befriend/internal/model/custom_type"
	"befriend/internal/services/trigger_event"
	"befriend/pkg/utils/errors"
)

const maxExcludedApps = 100

type SettingsResponse struct {
	LogSyncPaused bool     `json:"log_sync_paused"`
	ExcludedApps  []string `json:"excluded_apps"`
	SkinID        *string  `json:"skin_id"` // null = the built-in skin
	userID        string
	// PendingSkin is a pick whose phrasebook is still being written ("getting dressed"); null when none.
	PendingSkin *PendingSkin `json:"pending_skin"`
}

// PendingSkin names the skin a pick switches to once its phrasebook is ready.
type PendingSkin struct {
	SkinID *string `json:"skin_id"` // null = the built-in skin
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
	return s.withPending(ctx, toSettings(owner))
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
		response, err = s.withPending(ctx, toSettings(owner))
		return err
	})
	if err != nil {
		return nil, err
	}
	return response, nil
}

// withPending adds the skin pick still being written for, if any.
func (s *userApplicationService) withPending(ctx context.Context, settings *SettingsResponse) (*SettingsResponse, error) {
	f, err := s.readyFriend(ctx, settings.userID)
	if err != nil || f == nil {
		return settings, err
	}
	job, err := s.personalityVersionService.GetActiveReskin(ctx, f.ID)
	if err != nil || job == nil {
		return settings, err
	}
	settings.PendingSkin = &PendingSkin{SkinID: job.SkinID}
	return settings, nil
}

// readyFriend is the account's friend once it has a personality; nil while onboarding or hatching.
func (s *userApplicationService) readyFriend(ctx context.Context, userID string) (*model.Friend, error) {
	f, err := s.friendService.GetByUserID(ctx, userID)
	if errors.Is(err, "DATA_NOT_FOUND") {
		return nil, nil
	}
	if err != nil || f.CurrentVersionID == nil {
		return nil, err
	}
	return f, nil
}

// updateSkin starts a switch. Once the friend has a personality, its phrasebook is rewritten for the picked
// skin first and the switch applies when that's ready (see the personality worker); picking the current skin
// again cancels a switch in progress. Before then there is no phrasebook to rewrite, so the pick applies at once.
func (s *userApplicationService) updateSkin(ctx context.Context, owner *model.User, skinID string) error {
	var next *string
	if skinID != "" {
		granted, err := s.skinService.IsGranted(ctx, owner.ID, skinID)
		if err != nil {
			return err
		}
		if !granted {
			return errors.From("SKIN_NOT_FOUND")
		}
		next = &skinID
	}
	f, err := s.readyFriend(ctx, owner.ID)
	if err != nil {
		return err
	}
	switch {
	case f == nil && sameSkin(owner.SkinID, next):
		return nil
	case f == nil:
		if err := s.userService.UpdateSkin(ctx, owner.ID, next); err != nil {
			return err
		}
		owner.SkinID = next
	case sameSkin(owner.SkinID, next):
		if err := s.personalityVersionService.AbandonReskins(ctx, f.ID, "the user kept their skin"); err != nil {
			return err
		}
	default:
		if _, err := s.personalityVersionService.CreateReskin(ctx, f.ID, next); err != nil {
			return err
		}
	}
	return s.skinService.NotifyUser(ctx, owner.ID) // other devices show the switch, pending or done
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
	return &SettingsResponse{LogSyncPaused: owner.LogSyncPaused, ExcludedApps: apps, SkinID: owner.SkinID, userID: owner.ID}
}
