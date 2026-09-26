package personality_version

import (
	"context"
	"encoding/json"
	"time"

	"befriend/internal/model"
	"befriend/internal/model/enum"
	"befriend/pkg/clients/db"
)

type PersonalityVersionRepo interface {
	Create(ctx context.Context, m *model.PersonalityVersion) (*model.PersonalityVersion, error)
	GetByID(ctx context.Context, id string) (*model.PersonalityVersion, error)
	// GetLatestByFriend skips abandoned versions.
	GetLatestByFriend(ctx context.Context, friendID string) (*model.PersonalityVersion, error)
	// NextVersion numbers a new version after every existing one, abandoned included. Call it inside the
	// transaction that creates the version: it locks the friend's numbering until that commits.
	NextVersion(ctx context.Context, friendID string) (int, error)
	// GetActiveReskin returns the friend's reskin still queued, running or retrying; nil when there is none.
	GetActiveReskin(ctx context.Context, friendID string) (*model.PersonalityVersion, error)
	AbandonReskins(ctx context.Context, friendID, reason string, now time.Time) error
	ClaimDue(ctx context.Context, now time.Time, limit int, lockedUntil time.Time) ([]model.PersonalityVersion, error)
	MarkReady(ctx context.Context, claim Claim, llmModel string, vocabularyVersion int, personality, phrasebook json.RawMessage, now time.Time) error
	Reschedule(ctx context.Context, claim Claim, status enum.PersonalityStatus, nextAttemptAt time.Time, reason string, countAttempt bool, now time.Time) error
}

// Claim identifies a job as claimed by one ClaimDue call: a later claim of the same row sets a new LockedUntil.
type Claim struct {
	ID          string
	LockedUntil time.Time
}

type personalityVersionRepo struct {
	dbdget db.DBGormDelegate
}

func NewPersonalityVersionRepo(dbdget db.DBGormDelegate) PersonalityVersionRepo {
	return &personalityVersionRepo{
		dbdget: dbdget,
	}
}
