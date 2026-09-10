package presence

import (
	"time"

	"befriend/internal/model"
)

type Owner string

const (
	OwnerPhone Owner = "phone"
	OwnerMac   Owner = "mac"
)

const (
	// MacTimeout: a Mac heartbeats every 30 seconds; three missed beats and it's gone.
	MacTimeout = 90 * time.Second
	// PhoneClaimDuration: the iPhone app renews its claim every minute while in the foreground.
	PhoneClaimDuration = 5 * time.Minute
	// PushDebounce limits APNs pushes per user.
	PushDebounce = 30 * time.Second
)

type StateResponse struct {
	Owner     Owner     `json:"owner"`
	ChangedAt time.Time `json:"changed_at"`
}

// DecideOwner: the iPhone while its app claims the friend, else the Mac while its user is active and it was
// heard from recently, else the iPhone.
func DecideOwner(p *model.Presence, now time.Time) Owner {
	if p.PhoneClaimUntil != nil && now.Before(*p.PhoneClaimUntil) {
		return OwnerPhone
	}
	if p.MacActive && p.MacSeenAt != nil && now.Sub(*p.MacSeenAt) <= MacTimeout {
		return OwnerMac
	}
	return OwnerPhone
}
