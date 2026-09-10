// Package vocabulary is the fixed set of actions, moods and trigger kinds shared by the backend and the
// apps. Every character skin draws every action; the LLM may only use these values. Any change is a new
// Version, shipped in lockstep with PetCore.
package vocabulary

import "slices"

const Version = 1

var (
	Actions = []string{
		"idle", "wave", "nudge", "sleep", "celebrate", "dance", "laugh", "cry", "yawn", "stretch",
		"think", "peek", "hide", "shrug", "facepalm", "cheer", "jump", "spin", "sit", "love",
	}
	Moods = []string{
		"content", "curious", "concerned", "excited", "sleepy", "bored",
		"playful", "proud", "shy", "grumpy", "calm", "lonely",
	}
	// TriggerKinds are the moments the friend reacts to; each gets phrasebook lines for every mood.
	TriggerKinds = []string{"app_switched", "went_idle", "returned", "left_app", "poked", "check_in"}
)

func IsAction(s string) bool      { return slices.Contains(Actions, s) }
func IsMood(s string) bool        { return slices.Contains(Moods, s) }
func IsTriggerKind(s string) bool { return slices.Contains(TriggerKinds, s) }
