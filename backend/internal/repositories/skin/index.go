package skin

import (
	"context"

	"befriend/internal/model"
	"befriend/pkg/clients/db"
)

// NotifyChannel is the Postgres channel carrying a user ID whenever that account's skins or skin pick change.
const NotifyChannel = "skin_changed"

// SkinRepo stores published skins and the accounts granted them, and queues the notifications apps react to.
type SkinRepo interface {
	// ListGranted returns the skins the user may use, without their archives.
	ListGranted(ctx context.Context, userID string) ([]model.SkinSummary, error)
	// GetGranted returns a skin with its archive, or DATA_NOT_FOUND unless the user was granted it.
	GetGranted(ctx context.Context, userID, skinID string) (*model.Skin, error)
	// Publish stores the archive and bumps the version. An identical archive (same sha256) keeps the version and
	// returns changed false.
	Publish(ctx context.Context, m model.Skin) (version int, changed bool, err error)
	// Grant is idempotent (false when the account already had it); DATA_NOT_FOUND when the skin isn't published.
	Grant(ctx context.Context, userID, skinID string) (bool, error)
	// Revoke deletes the grant (a foreign key clears the account's pick of it); false when there was none.
	Revoke(ctx context.Context, userID, skinID string) (bool, error)
	// NotifyUser and NotifySelected queue skin_changed notifications, delivered when the transaction commits.
	NotifyUser(ctx context.Context, userID string) error
	NotifySelected(ctx context.Context, skinID string) error
}

type skinRepo struct {
	dbdget db.DBGormDelegate
}

func NewSkinRepo(dbdget db.DBGormDelegate) SkinRepo {
	return &skinRepo{
		dbdget: dbdget,
	}
}
