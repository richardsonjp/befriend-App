package vocabulary

import (
	"regexp"
	"testing"
)

// The apps decode these as enum raw values, so they must stay unique snake_case identifiers.
func TestVocabularyShape(t *testing.T) {
	identifier := regexp.MustCompile(`^[a-z][a-z_]*$`)
	tests := []struct {
		name  string
		list  []string
		count int
	}{
		{"actions", Actions, 20},
		{"moods", Moods, 12},
		{"trigger kinds", TriggerKinds, 6},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if len(tt.list) != tt.count {
				t.Fatalf("%d entries; vocabulary v%d defines %d", len(tt.list), Version, tt.count)
			}
			seen := map[string]bool{}
			for _, v := range tt.list {
				if !identifier.MatchString(v) {
					t.Errorf("%q is not a snake_case identifier", v)
				}
				if seen[v] {
					t.Errorf("%q is listed twice", v)
				}
				seen[v] = true
			}
		})
	}
	if !IsAction("wave") || IsAction("fly") || !IsMood("shy") || IsMood("angry") || !IsTriggerKind("poked") || IsTriggerKind("sneezed") {
		t.Fatal("membership helpers disagree with the lists")
	}
}
