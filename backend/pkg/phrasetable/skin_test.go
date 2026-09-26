package phrasetable

import (
	"strings"
	"testing"

	"befriend/pkg/utils/vocabulary"
)

func TestBuiltInGrammarIsUnchanged(t *testing.T) {
	// The v1 grammar the existing fine-tune and training data were made under.
	g := ChunkGrammar(vocabulary.Skin{})
	for _, want := range []string{
		"root ::= mood-content mood-curious mood-concerned",
		`mood-lonely ::= "lonely" "\n" line line line?`,
		`action ::= "idle" | "wave" | "nudge"`,
	} {
		if !strings.Contains(g, want) {
			t.Errorf("built-in grammar lacks %q", want)
		}
	}
}

func TestChunkForASkin(t *testing.T) {
	skin := vocabulary.FromClips([]string{"idle", "jump", "idle/fired_up", "float/zen", "idle/zen"})
	g := ChunkGrammar(skin)
	for _, want := range []string{
		"root ::= mood-0 mood-1",
		`mood-0 ::= "fired_up" "\n" line-0 line-0 line-0?`,
		`action-0 ::= "idle" | "jump"`,
		`action-1 ::= "float" | "idle" | "jump"`,
	} {
		if !strings.Contains(g, want) {
			t.Errorf("grammar lacks %q:\n%s", want, g)
		}
	}

	byMood := map[string][]Line{
		"fired_up": {{"jump", "Let's gooo!"}, {"idle", "Ready when you are."}},
		"zen":      {{"float", "Breathe in, breathe out."}, {"idle", "All is calm here."}},
	}
	encoded, err := EncodeChunk(byMood, skin)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := DecodeChunk(encoded, skin)
	if err != nil || decoded["zen"][0].Action != "float" {
		t.Fatalf("round trip: %v, %v", decoded, err)
	}
	if _, err := DecodeChunk(strings.Replace(encoded, "float|", "wave|", 1), skin); err == nil {
		t.Error("an action the skin doesn't have decoded")
	}
}
