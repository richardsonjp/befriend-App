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
// for it; picking another skin tells the account's other devices once the change commits. A skin pick for a
// hatched friend waits while its phrasebook is rewritten (see pickSkin); if that fails, the other fields are
// saved and the skin stays as it was.
func (s *userApplicationService) UpdateSettings(ctx context.Context, userID string, payload UpdateSettingsPayload) (*SettingsResponse, error) {
	var owner *model.User
	var reskin *pendingReskin
	err := s.txRepo.Run(ctx, func(ctx context.Context) error {
		var err error
		owner, err = s.userService.GetUserByID(ctx, userID)
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
			reskin, err = s.pickSkin(ctx, owner, *payload.SkinID)
		}
		return err
	})
	if err != nil {
		return nil, err
	}
	// Outside the transaction: writing a phrasebook takes up to several minutes.
	if reskin != nil {
		if err := s.personalityService.Reskin(ctx, reskin.friendID, reskin.skinID); err != nil {
			return nil, err
		}
		owner.SkinID = reskin.skinID
	}
	return toSettings(owner), nil
}

// pendingReskin is a skin pick that needs the friend's phrasebook rewritten before it applies.
type pendingReskin struct {
	friendID string
	skinID   *string // nil = the built-in skin
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

// pickSkin checks the pick. Before the friend hatches there is no phrasebook to rewrite, so the pick applies at
// once (the hatch then writes for it). After, it returns the rewrite for UpdateSettings to run; the switch
// applies when that's written. Picking the skin the user has is a no-op.
func (s *userApplicationService) pickSkin(ctx context.Context, owner *model.User, skinID string) (*pendingReskin, error) {
	var next *string
	if skinID != "" {
		granted, err := s.skinService.IsGranted(ctx, owner.ID, skinID)
		if err != nil {
			return nil, err
		}
		if !granted {
			return nil, errors.From("SKIN_NOT_FOUND")
		}
		next = &skinID
	}
	if sameSkin(owner.SkinID, next) {
		return nil, nil
	}
	f, err := s.readyFriend(ctx, owner.ID)
	if err != nil {
		return nil, err
	}
	if f != nil {
		return &pendingReskin{friendID: f.ID, skinID: next}, nil
	}
	if err := s.userService.UpdateSkin(ctx, owner.ID, next); err != nil {
		return nil, err
	}
	owner.SkinID = next
	return nil, s.skinService.NotifyUser(ctx, owner.ID) // other devices show the switch
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
