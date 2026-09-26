package skin

import (
	"context"

	"befriend/internal/model"
	repoSkin "befriend/internal/repositories/skin"
	"befriend/internal/repositories/tx"
	"befriend/internal/services/user"
	"befriend/pkg/skinpack"
	"befriend/pkg/utils/vocabulary"
)

// NotifyChannel carries a user ID whenever that account's skins or skin pick change.
const NotifyChannel = repoSkin.NotifyChannel

type SkinService interface {
	// List returns the skins the account was granted (the built-in skin isn't listed).
	List(ctx context.Context, userID string) ([]SkinResponse, error)
	// GetArchive returns a granted skin with its zip; SKIN_NOT_FOUND otherwise.
	GetArchive(ctx context.Context, userID, skinID string) (*model.Skin, error)
	// Publish stores a built skin; changed is false when the same content was already published. artistID is who
	// made it (nil: published from the repo).
	Publish(ctx context.Context, pkg *skinpack.Package, artistID *string) (version int, changed bool, err error)
	// Submit stores an invited artist's upload (their zipped skin folder) for review, once it builds.
	Submit(ctx context.Context, userID, skinID string, upload []byte) (*SubmissionResponse, error)
	// ListSubmissions lists an artist's submissions (userID set) or, for review, every pending one.
	ListSubmissions(ctx context.Context, userID *string) ([]SubmissionResponse, error)
	// GetSubmission returns a submission with its upload, for review.
	GetSubmission(ctx context.Context, id string) (*model.SkinSubmission, error)
	// Approve publishes a pending submission as its artist's skin.
	Approve(ctx context.Context, id string) (*skinpack.Package, int, error)
	// Reject records why a pending submission won't be published.
	Reject(ctx context.Context, id, note string) error
	// SetArtist invites an account to submit skins, or stops it.
	SetArtist(ctx context.Context, payload GrantPayload, artist bool) error
	Grant(ctx context.Context, payload GrantPayload) error
	// Revoke takes a skin away; an account using it goes back to the built-in skin. False when it wasn't granted.
	Revoke(ctx context.Context, payload GrantPayload) (bool, error)
	// Vocabulary is what a skin lets its friend's phrasebook use; nil is the built-in skin.
	Vocabulary(ctx context.Context, skinID *string) (vocabulary.Skin, error)
	// IsGranted reports whether the account may pick the skin.
	IsGranted(ctx context.Context, userID, skinID string) (bool, error)
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
