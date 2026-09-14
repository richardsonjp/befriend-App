package presence

import "sync"

// Message is what a Mac's presence connection receives: the owner, and/or that the account's skin changed.
type Message struct {
	Owner       Owner `json:"owner,omitempty"`
	SkinChanged bool  `json:"skin_changed,omitempty"`
}

// hub fans messages out to the user's open Mac connections.
// ponytail: in memory, so one API instance; fan out with Postgres LISTEN/NOTIFY when running several.
type hub struct {
	mu   sync.Mutex
	subs map[string]map[chan Message]struct{}
}

func newHub() *hub {
	return &hub{subs: map[string]map[chan Message]struct{}{}}
}

func (h *hub) subscribe(userID string) (chan Message, func() bool) {
	ch := make(chan Message, 1)
	h.mu.Lock()
	if h.subs[userID] == nil {
		h.subs[userID] = map[chan Message]struct{}{}
	}
	h.subs[userID][ch] = struct{}{}
	h.mu.Unlock()

	return ch, func() bool {
		h.mu.Lock()
		defer h.mu.Unlock()
		delete(h.subs[userID], ch)
		if len(h.subs[userID]) == 0 {
			delete(h.subs, userID)
			return true
		}
		return false
	}
}

// publish delivers without blocking. An unread message is merged into the new one, so a slow reader sees the
// latest owner and still learns that the skin changed.
func (h *hub) publish(userID string, msg Message) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for ch := range h.subs[userID] {
		next := msg
		select {
		case old := <-ch:
			next.SkinChanged = next.SkinChanged || old.SkinChanged
			if next.Owner == "" {
				next.Owner = old.Owner
			}
		default:
		}
		ch <- next
	}
}
