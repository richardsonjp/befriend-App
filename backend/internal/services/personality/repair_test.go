package personality

import (
	"strings"
	"testing"
	"unicode/utf8"

	"befriend/pkg/utils/vocabulary"
)

// The slips seen from free models in production, each of which used to fail a whole hatch.
func TestRepairSavesAPersonalityFromSmallSlips(t *testing.T) {
	g := validGenerated()
	g.Voice = strings.Repeat("Soft and playful, with little puns tucked in. ", 5) // 230 characters
	g.Traits = append(g.Traits, "a trait far too long to be one trait at all", "cozy")
	for i, e := range g.Phrasebook {
		switch {
		case e.Trigger == "went_idle" && e.Mood == "curious":
			g.Phrasebook[i].Lines[0].Text = "Where did {app} go?"
		case e.Trigger == "poked" && e.Mood == "shy":
			g.Phrasebook[i].Lines = append(g.Phrasebook[i].Lines, PhraseLine{Text: "Hey there!", Action: "wave"})
		case e.Trigger == "check_in" && e.Mood == "calm":
			g.Phrasebook[i].Lines[1] = PhraseLine{Text: "Just an AI checking in.", Action: "wave"}
		case e.Trigger == "returned" && e.Mood == "bored":
			g.Phrasebook[i].Lines[0].Action = "moonwalk"
		}
	}
	g.Phrasebook = append(g.Phrasebook[:5], g.Phrasebook[6:]...) // one entry skipped

	Repair(g, vocabulary.Skin{})
	p, book, err := Validate(g, vocabulary.Skin{})
	if err != nil {
		t.Fatalf("repaired output still rejected: %v", err)
	}
	if n := utf8.RuneCountInString(p.Voice); n > maxVoice || !strings.HasSuffix(p.Voice, ".") {
		t.Errorf("voice = %q (%d)", p.Voice, n)
	}
	if book["went_idle"]["curious"][0].Text != "Where did that app go?" {
		t.Errorf("{app} outside app switches = %q", book["went_idle"]["curious"][0].Text)
	}
	if book["returned"]["bored"][0].Action != "idle" {
		t.Error("an invented action wasn't made idle")
	}
	// check_in/calm lost its AI line and fell under two lines, so it was refilled from another mood.
	for _, line := range book["check_in"]["calm"] {
		if strings.Contains(line.Text, "AI") {
			t.Error("a line breaking character survived")
		}
	}
}

func TestRepairKeepsWhatCantBeFixed(t *testing.T) {
	g := validGenerated()
	g.Instructions = "You are Mochi. Call me Nia and keep it playful, warm and short."
	Repair(g, vocabulary.Skin{})
	if _, _, err := Validate(g, vocabulary.Skin{}); err == nil || !strings.Contains(err.Error(), "first person") {
		t.Errorf("first-person instructions: %v", err)
	}
}

func TestShorten(t *testing.T) {
	for _, tt := range []struct{ in, want string }{
		{"Short.", "Short."},
		{"One sentence here. Then a second one that runs well past the limit", "One sentence here."},
		{"no sentence end in this whole long run of words at all", "no sentence end in this whole…"},
	} {
		if got := shorten(tt.in, 31); got != tt.want {
			t.Errorf("shorten(%q) = %q; want %q", tt.in, got, tt.want)
		}
	}
}
