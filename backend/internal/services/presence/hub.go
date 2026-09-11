package presence

import "sync"

// hub fans owner changes out to the user's open Mac connections.
// ponytail: in memory, so one API instance; fan out with Postgres LISTEN/NOTIFY when running several.
type hub struct {
	mu   sync.Mutex
	subs map[string]map[chan Owner]struct{}
}

func newHub() *hub {
	return &hub{subs: map[string]map[chan Owner]struct{}{}}
}

func (h *hub) subscribe(userID string) (chan Owner, func() bool) {
	ch := make(chan Owner, 1)
	h.mu.Lock()
	if h.subs[userID] == nil {
		h.subs[userID] = map[chan Owner]struct{}{}
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

// publish delivers the latest owner without blocking: a slow reader only ever sees the newest value.
func (h *hub) publish(userID string, owner Owner) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for ch := range h.subs[userID] {
		select {
		case <-ch:
		default:
		}
		ch <- owner
	}
}
