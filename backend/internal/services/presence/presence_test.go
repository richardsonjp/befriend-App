package presence

import (
	"encoding/json"
	"testing"
	"time"

	"befriend/internal/model"
)

func TestDecideOwner(t *testing.T) {
	now := time.Date(2026, 9, 11, 10, 0, 0, 0, time.UTC)
	at := func(d time.Duration) *time.Time { v := now.Add(d); return &v }

	tests := []struct {
		name string
		p    model.Presence
		want Owner
	}{
		{"nothing known", model.Presence{}, OwnerPhone},
		{"active Mac, fresh heartbeat", model.Presence{MacActive: true, MacSeenAt: at(-30 * time.Second)}, OwnerMac},
		{"active Mac at the timeout edge", model.Presence{MacActive: true, MacSeenAt: at(-MacTimeout)}, OwnerMac},
		{"active Mac gone quiet", model.Presence{MacActive: true, MacSeenAt: at(-MacTimeout - time.Second)}, OwnerPhone},
		{"Mac idle or locked", model.Presence{MacActive: false, MacSeenAt: at(-5 * time.Second)}, OwnerPhone},
		{"iPhone app open beats an active Mac", model.Presence{MacActive: true, MacSeenAt: at(-5 * time.Second), PhoneClaimUntil: at(time.Minute)}, OwnerPhone},
		{"lapsed iPhone claim", model.Presence{MacActive: true, MacSeenAt: at(-5 * time.Second), PhoneClaimUntil: at(-time.Second)}, OwnerMac},
	}
	for _, tt := range tests {
		if got := DecideOwner(&tt.p, now); got != tt.want {
			t.Errorf("%s: got %s; want %s", tt.name, got, tt.want)
		}
	}
}

func TestSurfaceState(t *testing.T) {
	now := time.Unix(1_789_070_148, 0)
	book := json.RawMessage(`{"returned":{"excited":[{"text":"Back!","action":"wave"}]},"left_app":{"calm":[{"text":"See you there","action":"sit"}],"shy":[]}}`)
	first := func(int) int { return 0 }

	mac := surfaceState(OwnerMac, book, now, first)
	if mac != (SurfaceState{Presence: "mac", Mood: "calm", Action: "sit", Line: "See you there", UpdatedAt: 1_789_070_148}) {
		t.Errorf("mac state = %+v", mac)
	}
	phone := surfaceState(OwnerPhone, book, now, first)
	if phone.Presence != "here" || phone.Line != "Back!" || phone.Action != "wave" {
		t.Errorf("phone state = %+v", phone)
	}
	if blank := surfaceState(OwnerPhone, nil, now, first); blank.Line != "" || blank.Action != "idle" || blank.Presence != "here" {
		t.Errorf("no phrasebook = %+v", blank)
	}
}

func TestPayloads(t *testing.T) {
	now := time.Unix(1_789_070_148, 0)
	state := SurfaceState{Presence: "mac", Mood: "calm", Action: "sit", Line: "", UpdatedAt: 1}

	start, _ := json.Marshal(activityStartPayload(state, "Mochi", now))
	var decoded struct {
		APS struct {
			Event          string            `json:"event"`
			AttributesType string            `json:"attributes-type"`
			Attributes     map[string]string `json:"attributes"`
			Alert          map[string]string `json:"alert"`
			ContentState   map[string]any    `json:"content-state"`
			Timestamp      int64             `json:"timestamp"`
		} `json:"aps"`
	}
	if err := json.Unmarshal(start, &decoded); err != nil {
		t.Fatal(err)
	}
	a := decoded.APS
	if a.Event != "start" || a.AttributesType != "FriendActivityAttributes" || a.Attributes["friendName"] != "Mochi" || a.Alert["body"] == "" || a.Timestamp != now.Unix() {
		t.Errorf("start payload = %s", start)
	}
	for _, key := range []string{"presence", "mood", "action", "line", "updated_at"} {
		if _, ok := a.ContentState[key]; !ok {
			t.Errorf("content-state missing %q: %s", key, start)
		}
	}

	widget, _ := json.Marshal(widgetPayload())
	if string(widget) != `{"aps":{"content-changed":true}}` {
		t.Errorf("widget payload = %s", widget)
	}
}

func TestHubDeliversLatestAndCountsConnections(t *testing.T) {
	h := newHub()
	updates, unsubscribe := h.subscribe("u1")
	_, unsubscribeOther := h.subscribe("u1")

	h.publish("u1", Message{Owner: OwnerMac})
	h.publish("u1", Message{Owner: OwnerPhone}) // replaces the unread value instead of blocking
	if got := <-updates; got != (Message{Owner: OwnerPhone}) {
		t.Errorf("got %+v; want the latest owner", got)
	}

	// An unread skin change survives a later owner change, and the owner survives a later skin change.
	h.publish("u1", Message{SkinChanged: true})
	h.publish("u1", Message{Owner: OwnerMac})
	h.publish("u1", Message{SkinChanged: true})
	if got := <-updates; got != (Message{Owner: OwnerMac, SkinChanged: true}) {
		t.Errorf("got %+v; want the merged owner and skin change", got)
	}
	if encoded, _ := json.Marshal(Message{SkinChanged: true}); string(encoded) != `{"skin_changed":true}` {
		t.Errorf("skin message = %s", encoded)
	}
	if unsubscribe() {
		t.Error("first unsubscribe reported the last connection")
	}
	if !unsubscribeOther() {
		t.Error("second unsubscribe should be the last connection")
	}
}
