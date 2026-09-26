package vocabulary

import (
	"encoding/json"
	"fmt"
	"slices"
	"strings"
)

// AppPlayed are clips the apps play on their own (the Mac's walk, focusing during a pomodoro); the AI never
// picks them.
var AppPlayed = []string{"walk", "focus"}

// NoMood is the single mood of a skin drawn without moods; its head is mini/default.png.
const NoMood = "default"

// Skin is what a character skin can play, as the AI sees it: its moods, and the actions drawn for each.
type Skin struct {
	Moods   []string
	actions map[string][]string // mood → actions, in play order
}

// Default is the built-in pixel cat: every vocabulary action in every vocabulary mood.
func Default() Skin {
	s := Skin{Moods: slices.Clone(Moods), actions: map[string][]string{}}
	for _, mood := range Moods {
		s.actions[mood] = slices.Clone(Actions)
	}
	return s
}

// FromClips reads a published skin's clips ("wave" plays in any mood, "wave/grumpy" only in that mood). No clips
// (a skin published before clips were stored) means the built-in vocabulary.
func FromClips(clips []string) Skin {
	if len(clips) == 0 {
		return Default()
	}
	var plain []string
	byMood := map[string][]string{}
	for _, clip := range clips {
		action, mood, hasMood := strings.Cut(clip, "/")
		if slices.Contains(AppPlayed, action) {
			continue
		}
		if !hasMood {
			if !slices.Contains(plain, action) {
				plain = append(plain, action)
			}
		} else if !slices.Contains(byMood[mood], action) {
			byMood[mood] = append(byMood[mood], action)
		}
	}
	s := Skin{actions: map[string][]string{}}
	for mood := range byMood {
		s.Moods = append(s.Moods, mood)
	}
	slices.Sort(s.Moods)
	if len(s.Moods) == 0 {
		s.Moods = []string{NoMood}
	}
	for _, mood := range s.Moods {
		actions := slices.Clone(plain)
		for _, action := range byMood[mood] {
			if !slices.Contains(actions, action) {
				actions = append(actions, action)
			}
		}
		slices.Sort(actions)
		s.actions[mood] = actions
	}
	return s
}

// Actions is every action the skin has in some mood, in play order.
func (s Skin) Actions() []string {
	var all []string
	for _, mood := range s.Moods {
		for _, action := range s.actions[mood] {
			if !slices.Contains(all, action) {
				all = append(all, action)
			}
		}
	}
	return all
}

// ActionsFor lists the actions drawn for a mood.
func (s Skin) ActionsFor(mood string) []string { return s.actions[mood] }

// Uniform reports whether every mood can play every action, so one action list describes the skin.
func (s Skin) Uniform() bool {
	all := len(s.Actions())
	for _, mood := range s.Moods {
		if len(s.actions[mood]) != all {
			return false
		}
	}
	return true
}

func (s Skin) IsMood(mood string) bool         { return slices.Contains(s.Moods, mood) }
func (s Skin) IsAction(action string) bool     { return slices.Contains(s.Actions(), action) }
func (s Skin) Allows(action, mood string) bool { return slices.Contains(s.actions[mood], action) }

// skinJSON is how a skin travels in harvest files: its moods in order, and the actions drawn for each.
type skinJSON struct {
	Moods   []string            `json:"moods"`
	Actions map[string][]string `json:"actions"`
}

func (s Skin) MarshalJSON() ([]byte, error) {
	return json.Marshal(skinJSON{Moods: s.Moods, Actions: s.actions})
}

func (s *Skin) UnmarshalJSON(data []byte) error {
	var raw skinJSON
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	for _, mood := range raw.Moods {
		if len(raw.Actions[mood]) == 0 { // every real skin draws a plain idle, so no mood is empty
			return fmt.Errorf("skin mood %q has no actions", mood)
		}
	}
	*s = Skin{Moods: raw.Moods, actions: raw.Actions}
	return nil
}

// OrDefault is the skin, or the built-in one for the zero Skin.
func (s Skin) OrDefault() Skin {
	if len(s.Moods) == 0 {
		return Default()
	}
	return s
}
