package personality

import (
	"strings"
	"testing"

	"befriend/pkg/utils/vocabulary"
)

// validGenerated returns output that satisfies the whole contract; tests mutate a copy.
func validGenerated() *Generated {
	g := &Generated{
		Personality: Personality{
			Summary:      "A sleepy, curious cat who loves late-night coding sessions.",
			Traits:       []string{"curious", "gentle", "a bit dramatic"},
			Voice:        "Soft, playful, short sentences with the occasional pun.",
			Instructions: "You are Mochi. Speak warmly and briefly. Never mention being an AI.",
		},
	}
	for _, trigger := range vocabulary.TriggerKinds {
		for _, mood := range vocabulary.Moods {
			text := "Hey there!"
			if trigger == "app_switched" {
				text = "Ooh, {app} again?"
			}
			g.Phrasebook = append(g.Phrasebook, PhraseEntry{
				Trigger: trigger,
				Mood:    mood,
				Lines:   []PhraseLine{{Text: text, Action: "wave"}, {Text: "Mhm.", Action: "idle"}},
			})
		}
	}
	return g
}

func TestValidate(t *testing.T) {
	tests := []struct {
		name    string
		mutate  func(g *Generated)
		wantErr string
	}{
		{name: "valid output", mutate: func(g *Generated) {}},
		{name: "instructions may say never mention being an AI", mutate: func(g *Generated) {}},
		{name: "whitespace, control and invisible characters are cleaned, not rejected", mutate: func(g *Generated) {
			g.Summary = "  A sleepy\n\tcat  "
			g.Voice = "Soft\u202e and \u200bplayful"
			g.Phrasebook[0].Lines[0].Text = "Hi\x00 there"
		}},
		{name: "empty summary", mutate: func(g *Generated) { g.Summary = " \n " }, wantErr: "summary: empty"},
		{name: "summary too long", mutate: func(g *Generated) { g.Summary = strings.Repeat("a", maxSummary+1) }, wantErr: "summary"},
		{name: "instructions too long", mutate: func(g *Generated) { g.Instructions = strings.Repeat("é", maxInstructions+1) }, wantErr: "instructions"},
		{name: "too few traits", mutate: func(g *Generated) { g.Traits = g.Traits[:2] }, wantErr: "traits"},
		{name: "too many traits", mutate: func(g *Generated) { g.Traits = []string{"a", "b", "c", "d", "e", "f"} }, wantErr: "traits"},
		{name: "trait too long", mutate: func(g *Generated) { g.Traits[0] = strings.Repeat("x", maxTrait+1) }, wantErr: "trait"},
		{name: "summary breaks character", mutate: func(g *Generated) { g.Summary = "An AI companion for your desktop." }, wantErr: "being an AI"},
		{name: "line breaks character", mutate: func(g *Generated) { g.Phrasebook[3].Lines[1].Text = "As a language model, hi." }, wantErr: "being an AI"},
		{name: "words merely containing 'ai' are fine", mutate: func(g *Generated) { g.Phrasebook[3].Lines[1].Text = "Rainy days are nice." }},
		{name: "missing slot", mutate: func(g *Generated) { g.Phrasebook = g.Phrasebook[1:] }, wantErr: "missing"},
		{name: "duplicate slot", mutate: func(g *Generated) { g.Phrasebook[1] = g.Phrasebook[0] }, wantErr: "more than once"},
		{name: "unknown mood", mutate: func(g *Generated) { g.Phrasebook[0].Mood = "furious" }, wantErr: "unknown trigger or mood"},
		{name: "unknown trigger", mutate: func(g *Generated) { g.Phrasebook[0].Trigger = "sneezed" }, wantErr: "unknown trigger or mood"},
		{name: "one line is too few", mutate: func(g *Generated) { g.Phrasebook[0].Lines = g.Phrasebook[0].Lines[:1] }, wantErr: "lines"},
		{name: "four lines are too many", mutate: func(g *Generated) {
			g.Phrasebook[0].Lines = append(g.Phrasebook[0].Lines, g.Phrasebook[0].Lines...)
		}, wantErr: "lines"},
		{name: "line too long", mutate: func(g *Generated) { g.Phrasebook[0].Lines[0].Text = strings.Repeat("a", maxLineText+1) }, wantErr: "max 80"},
		{name: "action outside vocabulary", mutate: func(g *Generated) { g.Phrasebook[0].Lines[0].Action = "fly" }, wantErr: "unknown action"},
		{name: "{app} outside app switches", mutate: func(g *Generated) {
			for i := range g.Phrasebook {
				if g.Phrasebook[i].Trigger == "poked" {
					g.Phrasebook[i].Lines[0].Text = "You poked me from {app}!"
					return
				}
			}
		}, wantErr: "placeholder {app} not allowed"},
		{name: "other placeholders never allowed", mutate: func(g *Generated) { g.Phrasebook[0].Lines[0].Text = "Hi {user}!" }, wantErr: "placeholder {user}"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			g := validGenerated()
			tt.mutate(g)
			p, book, err := Validate(g)
			if tt.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), tt.wantErr) {
					t.Fatalf("error = %v; want one containing %q", err, tt.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if len(book) != len(vocabulary.TriggerKinds) || len(book["poked"]) != len(vocabulary.Moods) {
				t.Fatalf("phrasebook shape = %d triggers, %d moods for poked", len(book), len(book["poked"]))
			}
			if strings.ContainsAny(p.Summary, "\n\t") || strings.HasPrefix(p.Summary, " ") {
				t.Fatalf("summary not cleaned: %q", p.Summary)
			}
			for _, lines := range book[vocabulary.TriggerKinds[0]] {
				for _, l := range lines {
					if strings.ContainsRune(l.Text, 0) {
						t.Fatalf("control character survived: %q", l.Text)
					}
				}
			}
		})
	}
}
