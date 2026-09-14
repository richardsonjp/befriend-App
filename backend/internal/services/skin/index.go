package skin

import (
	"context"

	"befriend/internal/model"
	repoSkin "befriend/internal/repositories/skin"
	"befriend/internal/repositories/tx"
	"befriend/internal/services/user"
	"befriend/pkg/skinpack"
)

// NotifyChannel carries a user ID whenever that account's skins or skin pick change.
const NotifyChannel = repoSkin.NotifyChannel

type SkinService interface {
	// List returns the skins the account was granted (the built-in skin isn't listed).
	List(ctx context.Context, userID string) ([]SkinResponse, error)
	// GetArchive returns a granted skin with its zip; SKIN_NOT_FOUND otherwise.
	GetArchive(ctx context.Context, userID, skinID string) (*model.Skin, error)
	// Publish stores a built skin; changed is false when the same content was already published.
	Publish(ctx context.Context, pkg *skinpack.Package) (version int, changed bool, err error)
	Grant(ctx context.Context, payload GrantPayload) error
	// Revoke takes a skin away; an account using it goes back to the built-in skin. False when it wasn't granted.
	Revoke(ctx context.Context, payload GrantPayload) (bool, error)
	// NotifyUser tells the account's apps to fetch their skin again, once the current transaction commits.
	NotifyUser(ctx context.Context, userID string) error
}

type skinService struct {
	txRepo      tx.TxRepo
	skinRepo    repoSkin.SkinRepo
	userService user.UserService
}

func NewSkinService(txRepo tx.TxRepo, skinRepo repoSkin.SkinRepo, userService user.UserService) SkinService {
	return &skinService{
		txRepo:      txRepo,
		skinRepo:    skinRepo,
		userService: userService,
	}
}
