package skin

import (
	"context"
	"fmt"
	"regexp"

	"befriend/internal/model"
	"befriend/pkg/skinpack"
	"befriend/pkg/utils/errors"
)

var idPattern = regexp.MustCompile(`^[a-z0-9-]{1,40}$`)

type SkinResponse struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	Version int    `json:"version"`
	SHA256  string `json:"sha256"`
	Size    int    `json:"size"` // zip bytes
}

// GrantPayload names the account by exactly one of Email or UserID.
type GrantPayload struct {
	SkinID string
	Email  string
	UserID string
}

func (s *skinService) List(ctx context.Context, userID string) ([]SkinResponse, error) {
	skins, err := s.skinRepo.ListGranted(ctx, userID)
	if err != nil {
		return nil, err
	}
	response := make([]SkinResponse, 0, len(skins))
	for _, m := range skins {
		response = append(response, SkinResponse{ID: m.ID, Name: m.Name, Version: m.Version, SHA256: m.SHA256, Size: m.Size})
	}
	return response, nil
}

func (s *skinService) GetArchive(ctx context.Context, userID, skinID string) (*model.Skin, error) {
	if !idPattern.MatchString(skinID) {
		return nil, errors.From("SKIN_NOT_FOUND")
	}
	m, err := s.skinRepo.GetGranted(ctx, userID, skinID)
	if errors.Is(err, "DATA_NOT_FOUND") {
		return nil, errors.From("SKIN_NOT_FOUND")
	}
	return m, err
}

func (s *skinService) Publish(ctx context.Context, pkg *skinpack.Package) (int, bool, error) {
	var version int
	var changed bool
	err := s.txRepo.Run(ctx, func(ctx context.Context) error {
		var err error
		version, changed, err = s.skinRepo.Publish(ctx, model.Skin{ID: pkg.ID, Name: pkg.Name, SHA256: pkg.SHA256, Archive: pkg.Zip})
		if err != nil || !changed {
			return err
		}
		return s.skinRepo.NotifySelected(ctx, pkg.ID)
	})
	return version, changed, err
}

func (s *skinService) Grant(ctx context.Context, payload GrantPayload) error {
	return s.txRepo.Run(ctx, func(ctx context.Context) error {
		userID, err := s.resolveUser(ctx, payload)
		if err != nil {
			return err
		}
		granted, err := s.skinRepo.Grant(ctx, userID, payload.SkinID)
		if errors.Is(err, "DATA_NOT_FOUND") {
			return errors.From("SKIN_NOT_FOUND")
		}
		if err != nil || !granted {
			return err
		}
		return s.skinRepo.NotifyUser(ctx, userID)
	})
}

func (s *skinService) Revoke(ctx context.Context, payload GrantPayload) (bool, error) {
	var revoked bool
	err := s.txRepo.Run(ctx, func(ctx context.Context) error {
		userID, err := s.resolveUser(ctx, payload)
		if err != nil {
			return err
		}
		if revoked, err = s.skinRepo.Revoke(ctx, userID, payload.SkinID); err != nil || !revoked {
			return err
		}
		return s.skinRepo.NotifyUser(ctx, userID)
	})
	return revoked, err
}

func (s *skinService) NotifyUser(ctx context.Context, userID string) error {
	return s.skinRepo.NotifyUser(ctx, userID)
}

func (s *skinService) resolveUser(ctx context.Context, payload GrantPayload) (string, error) {
	var account *model.User
	var err error
	switch {
	case (payload.Email == "") == (payload.UserID == ""):
		return "", fmt.Errorf("name the account with exactly one of email or user ID")
	case payload.Email != "":
		account, err = s.userService.GetUserByEmail(ctx, payload.Email)
	default:
		account, err = s.userService.GetUserByID(ctx, payload.UserID)
	}
	if errors.Is(err, "DATA_NOT_FOUND") {
		return "", fmt.Errorf("no account with that email or user ID")
	}
	if err != nil {
		return "", err
	}
	return account.ID, nil
}
