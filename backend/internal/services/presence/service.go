package presence

import (
	"context"
	"time"

	"befriend/internal/model"
	"befriend/pkg/utils/errors"
	"befriend/pkg/utils/logs"
)

const sweepBatch = 500

func (s *presenceService) Get(ctx context.Context, userID string) (*StateResponse, error) {
	p, err := s.presenceRepo.Get(ctx, userID)
	if errors.Is(err, "DATA_NOT_FOUND") {
		return &StateResponse{Owner: OwnerPhone, ChangedAt: time.Now()}, nil
	}
	if err != nil {
		return nil, err
	}
	return &StateResponse{Owner: DecideOwner(p, time.Now()), ChangedAt: p.ChangedAt}, nil
}

func (s *presenceService) MacHeartbeat(ctx context.Context, userID string, active bool) error {
	_, err := s.update(ctx, userID, func(p *model.Presence, now time.Time) {
		p.MacActive = active
		p.MacSeenAt = &now
	})
	return err
}

func (s *presenceService) MacDisconnected(ctx context.Context, userID string, lastHeartbeat time.Time) error {
	_, err := s.update(ctx, userID, func(p *model.Presence, now time.Time) {
		// A new connection may have heartbeated after this one's last message: leave its state alone.
		if p.MacSeenAt == nil || !p.MacSeenAt.After(lastHeartbeat) {
			p.MacActive = false
		}
	})
	return err
}

func (s *presenceService) ClaimPhone(ctx context.Context, userID string) (*StateResponse, error) {
	return s.update(ctx, userID, func(p *model.Presence, now time.Time) {
		until := now.Add(PhoneClaimDuration)
		p.PhoneClaimUntil = &until
	})
}

func (s *presenceService) ReleasePhone(ctx context.Context, userID string) (*StateResponse, error) {
	return s.update(ctx, userID, func(p *model.Presence, now time.Time) {
		p.PhoneClaimUntil = nil
	})
}

func (s *presenceService) Sweep(ctx context.Context) error {
	now := time.Now()
	userIDs, err := s.presenceRepo.ListDue(ctx, now, now.Add(-MacTimeout), now.Add(-PushDebounce), sweepBatch)
	if err != nil {
		return err
	}
	for _, userID := range userIDs {
		if _, err := s.update(ctx, userID, func(*model.Presence, time.Time) {}); err != nil {
			logs.Log.Errorf("presence sweep %s: %v", userID, err)
		}
	}
	return nil
}

func (s *presenceService) Subscribe(userID string) (<-chan Message, func() bool) {
	return s.hub.subscribe(userID)
}

// NotifySkinChanged returns at once; the widget push runs in the background like presence pushes.
func (s *presenceService) NotifySkinChanged(userID string) {
	s.hub.publish(userID, Message{SkinChanged: true})
	if s.apns != nil {
		go s.pushWidgets(context.Background(), userID)
	}
}

// update applies a change under the row lock and re-decides the owner. After the commit it tells the user's Macs
// about an owner change and pushes to the iPhone, at most once per PushDebounce (the sweeper sends what was held
// back).
func (s *presenceService) update(ctx context.Context, userID string, change func(p *model.Presence, now time.Time)) (*StateResponse, error) {
	var state StateResponse
	var ownerChanged, pushNow bool
	err := s.txRepo.Run(ctx, func(ctx context.Context) error {
		p, err := s.presenceRepo.GetForUpdate(ctx, userID)
		if err != nil {
			return err
		}
		now := time.Now()
		change(p, now)

		if owner := DecideOwner(p, now); string(owner) != p.Owner {
			p.Owner = string(owner)
			p.ChangedAt = now
			ownerChanged = true
		}
		lastPush := time.Time{}
		if p.LastPushAt != nil {
			lastPush = *p.LastPushAt
		}
		if p.ChangedAt.After(lastPush) && now.Sub(lastPush) >= PushDebounce {
			p.LastPushAt = &now
			pushNow = true
		}
		state = StateResponse{Owner: Owner(p.Owner), ChangedAt: p.ChangedAt}
		return s.presenceRepo.Save(ctx, p)
	})
	if err != nil {
		return nil, err
	}

	if ownerChanged {
		s.hub.publish(userID, Message{Owner: state.Owner})
	}
	if pushNow && s.apns != nil {
		go s.push(context.Background(), userID, state.Owner)
	}
	return &state, nil
}
