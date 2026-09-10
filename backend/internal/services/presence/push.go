package presence

import (
	"context"
	"encoding/json"
	stderrors "errors"
	"math/rand/v2"
	"time"

	"befriend/internal/model"
	"befriend/pkg/clients/apns"
	"befriend/pkg/utils/logs"
)

const (
	// Live Activities end after 8 hours; an older update token is treated as dead and push-to-start is used.
	liveActivityUsableFor = 7*time.Hour + 30*time.Minute
	// Updates and widget reloads can wait for a good moment; push-to-start carries an alert and must be immediate.
	pushPriority  = 5
	startPriority = 10
)

// SurfaceState is the widget/Live Activity content state, keyed exactly like the app's FriendSurfaceState.
type SurfaceState struct {
	Presence  string  `json:"presence"` // here | mac
	Mood      string  `json:"mood"`
	Action    string  `json:"action"`
	Line      string  `json:"line"`
	UpdatedAt float64 `json:"updated_at"` // unix seconds
}

type phraseLine struct {
	Text   string `json:"text"`
	Action string `json:"action"`
}

// push tells the user's iPhones where the friend is: the Live Activity (updated, or started again if it ended) and
// the widget. Tokens APNs reports dead are cleared.
func (s *presenceService) push(ctx context.Context, userID string, owner Owner) {
	defer func() {
		if r := recover(); r != nil {
			logs.Log.Errorf("presence push %s panic: %v", userID, r)
		}
	}()

	devices, err := s.deviceService.ListPushTargets(ctx, userID)
	if err != nil || len(devices) == 0 {
		return
	}
	name, phrasebook := "Your friend", json.RawMessage(nil)
	if profile, err := s.friendService.GetProfile(ctx, userID); err == nil {
		name, phrasebook = profile.Name, profile.Phrasebook
	}
	now := time.Now()
	state := surfaceState(owner, phrasebook, now, rand.IntN)

	for _, d := range devices {
		sandbox := d.APNsEnv != nil && *d.APNsEnv == "sandbox"
		switch {
		case d.LAPushToken != nil && d.LAStartedAt != nil && now.Sub(*d.LAStartedAt) < liveActivityUsableFor:
			s.send(ctx, d, "la_push_token", apns.Notification{DeviceToken: *d.LAPushToken, Sandbox: sandbox, PushType: apns.PushTypeLiveActivity, Priority: pushPriority, Payload: activityUpdatePayload(state, now)})
		case d.LAPushToStartToken != nil:
			s.send(ctx, d, "la_push_to_start_token", apns.Notification{DeviceToken: *d.LAPushToStartToken, Sandbox: sandbox, PushType: apns.PushTypeLiveActivity, Priority: startPriority, Payload: activityStartPayload(state, name, now)})
		}
		if d.WidgetPushToken != nil {
			s.send(ctx, d, "widget_push_token", apns.Notification{DeviceToken: *d.WidgetPushToken, Sandbox: sandbox, PushType: apns.PushTypeWidgets, Priority: pushPriority, Payload: widgetPayload()})
		}
	}
}

func (s *presenceService) send(ctx context.Context, d model.Device, column string, n apns.Notification) {
	err := s.apns.Send(ctx, n)
	switch {
	case err == nil:
	case stderrors.Is(err, apns.ErrUnregistered):
		if err := s.deviceService.ClearPushToken(ctx, d.ID, column); err != nil {
			logs.Log.Errorf("presence push: clear %s for device %s: %v", column, d.ID, err)
		}
	default:
		logs.Log.Errorf("presence push to device %s (%s): %v", d.ID, column, err)
	}
}

// surfaceState picks a phrasebook line for the move: "returned" when the friend comes back to the iPhone,
// "left_app" when it goes to the Mac.
func surfaceState(owner Owner, phrasebook json.RawMessage, now time.Time, randIntN func(int) int) SurfaceState {
	state := SurfaceState{Presence: "here", Mood: "content", Action: "idle", UpdatedAt: float64(now.Unix())}
	kind := "returned"
	if owner == OwnerMac {
		state.Presence, kind = "mac", "left_app"
	}

	var book map[string]map[string][]phraseLine
	if json.Unmarshal(phrasebook, &book) != nil {
		return state
	}
	var moods []string
	for mood, lines := range book[kind] {
		if len(lines) > 0 {
			moods = append(moods, mood)
		}
	}
	if len(moods) == 0 {
		return state
	}
	sortStrings(moods) // map order is random; sort so randIntN alone decides
	mood := moods[randIntN(len(moods))]
	lines := book[kind][mood]
	line := lines[randIntN(len(lines))]
	state.Mood, state.Action, state.Line = mood, line.Action, line.Text
	return state
}

func activityUpdatePayload(state SurfaceState, now time.Time) map[string]interface{} {
	return map[string]interface{}{"aps": map[string]interface{}{
		"timestamp":     now.Unix(),
		"event":         "update",
		"content-state": state,
	}}
}

// activityStartPayload starts a new Live Activity (push-to-start needs the attributes and an alert).
func activityStartPayload(state SurfaceState, friendName string, now time.Time) map[string]interface{} {
	body := state.Line
	if body == "" {
		body = "Your friend is here."
	}
	return map[string]interface{}{"aps": map[string]interface{}{
		"timestamp":       now.Unix(),
		"event":           "start",
		"content-state":   state,
		"attributes-type": "FriendActivityAttributes",
		"attributes":      map[string]string{"friendName": friendName},
		"alert":           map[string]string{"title": friendName, "body": body},
	}}
}

func widgetPayload() map[string]interface{} {
	return map[string]interface{}{"aps": map[string]interface{}{"content-changed": true}}
}

func sortStrings(values []string) {
	for i := 1; i < len(values); i++ {
		for j := i; j > 0 && values[j] < values[j-1]; j-- {
			values[j], values[j-1] = values[j-1], values[j]
		}
	}
}
