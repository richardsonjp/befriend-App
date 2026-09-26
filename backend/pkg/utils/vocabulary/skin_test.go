package vocabulary

import (
	"slices"
	"testing"
)

func TestDefaultIsTheBuiltInVocabulary(t *testing.T) {
	s := Default()
	if !slices.Equal(s.Moods, Moods) || !slices.Equal(s.Actions(), Actions) || !s.Uniform() {
		t.Fatalf("default skin = %v / %v", s.Moods, s.Actions())
	}
	s.Moods[0] = "changed"
	if Moods[0] == "changed" {
		t.Fatal("Default shares the vocabulary's backing array")
	}
}

func TestFromClips(t *testing.T) {
	s := FromClips([]string{"idle", "walk", "jump", "focus", "idle/grumpy", "stomp/grumpy", "float/happy"})
	if !slices.Equal(s.Moods, []string{"grumpy", "happy"}) {
		t.Fatalf("moods = %v", s.Moods)
	}
	if got := s.ActionsFor("grumpy"); !slices.Equal(got, []string{"idle", "jump", "stomp"}) {
		t.Errorf("grumpy actions = %v; walk and focus are app-played", got)
	}
	if !s.Allows("float", "happy") || s.Allows("float", "grumpy") || s.Uniform() {
		t.Error("float is only drawn happy")
	}
	if !s.IsAction("stomp") || s.IsAction("walk") || s.IsMood("default") {
		t.Error("membership")
	}

	if twice := FromClips([]string{"idle", "jump", "idle", "idle/zen"}); len(twice.ActionsFor("zen")) != 2 {
		t.Errorf("a clip listed twice counts once: %v", twice.ActionsFor("zen"))
	}

	bare := FromClips([]string{"idle", "walk", "jump", "focus"})
	if !slices.Equal(bare.Moods, []string{NoMood}) || !slices.Equal(bare.Actions(), []string{"idle", "jump"}) {
		t.Errorf("mood-less skin = %v / %v", bare.Moods, bare.Actions())
	}
	if legacy := FromClips(nil); !slices.Equal(legacy.Actions(), Actions) {
		t.Error("a skin without stored clips uses the built-in vocabulary")
	}
}
