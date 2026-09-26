package skin

import (
	"context"
	"time"

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
	// GetClips returns a published skin's clips (not grant-checked: the worker writing a phrasebook asks);
	// DATA_NOT_FOUND when it isn't published.
	GetClips(ctx context.Context, skinID string) ([]string, error)
	// Grant is idempotent (false when the account already had it); DATA_NOT_FOUND when the skin isn't published.
	Grant(ctx context.Context, userID, skinID string) (bool, error)
	// Revoke deletes the grant (a foreign key clears the account's pick of it); false when there was none.
	Revoke(ctx context.Context, userID, skinID string) (bool, error)
	// Submissions (M9): artists' uploads and their review.
	CountPendingSubmissions(ctx context.Context, artistID string) (int64, error)
	CreateSubmission(ctx context.Context, m *model.SkinSubmission) error
	// ListSubmissions returns submissions without archives, newest first; nil artist and "" status list all.
	ListSubmissions(ctx context.Context, artistID *string, status string, limit int) ([]model.SkinSubmission, error)
	GetSubmission(ctx context.Context, id string) (*model.SkinSubmission, error)
	ReviewSubmission(ctx context.Context, id, status string, note *string, now time.Time) error
	GetArtist(ctx context.Context, skinID string) (artist *string, found bool, err error)
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
