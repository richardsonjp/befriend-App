package phrasetable

import (
	"encoding/json"
	"strings"
	"testing"

	"befriend/pkg/utils/vocabulary"
)

// sampleChunk builds one trigger's worth of lines: every mood, alternating 2 and 3 lines.
func sampleChunk() map[string][]Line {
	byMood := make(map[string][]Line, len(vocabulary.Moods))
	for i, mood := range vocabulary.Moods {
		count := MinLines + i%(MaxLines-MinLines+1)
		lines := make([]Line, 0, count)
		for n := range count {
			lines = append(lines, Line{
				Action: vocabulary.Actions[(i+n)%len(vocabulary.Actions)],
				Text:   "Back again already? I was just getting comfortable.",
			})
		}
		byMood[mood] = lines
	}
	return byMood
}

func TestChunkRoundTrip(t *testing.T) {
	want := sampleChunk()
	encoded, err := EncodeChunk(want)
	if err != nil {
		t.Fatalf("EncodeChunk: %v", err)
	}
	got, err := DecodeChunk(encoded)
	if err != nil {
		t.Fatalf("DecodeChunk: %v", err)
	}
	if len(got) != len(vocabulary.Moods) {
		t.Fatalf("got %d moods, want %d", len(got), len(vocabulary.Moods))
	}
	for mood, lines := range want {
		if len(got[mood]) != len(lines) {
			t.Fatalf("%s: got %d lines, want %d", mood, len(got[mood]), len(lines))
		}
		for i, line := range lines {
			if got[mood][i] != line {
				t.Errorf("%s line %d: got %+v, want %+v", mood, i, got[mood][i], line)
			}
		}
	}
	// A model that ends with a blank line or CRLF still parses.
	if _, err := DecodeChunk(strings.ReplaceAll(encoded, "\n", "\r\n") + "\n"); err != nil {
		t.Errorf("padded output: %v", err)
	}
}

func TestDecodeChunkRejects(t *testing.T) {
	good, err := EncodeChunk(sampleChunk())
	if err != nil {
		t.Fatalf("EncodeChunk: %v", err)
	}
	longText := strings.Repeat("x", MaxTextRunes+1)

	cases := []struct {
		name  string
		input string
		want  string
	}{
		// A dropped mood header merges two blocks, so it surfaces as the line count rather than the mood name.
		{"a missing mood header", strings.Replace(good, "curious\n", "", 1), "content: want 2–3 lines, got 5"},
		{"moods out of order", "curious\n" + strings.Replace(good, "curious\n", "", 1), `want mood "content"`},
		{"an unknown action", strings.Replace(good, "idle|", "sprint|", 1), `unknown action "sprint"`},
		{"an unknown mood", strings.Replace(good, "sleepy\n", "wistful\n", 1), `want mood "sleepy"`},
		{"an over-long line", strings.Replace(good, "idle|Back", "idle|"+longText+"Back", 1), "characters, max 80"},
		{"empty text", strings.Replace(good, "idle|Back again already? I was just getting comfortable.", "idle|", 1), "text: empty"},
		{"too few lines", strings.Replace(good, "idle|Back again already? I was just getting comfortable.\n", "", 1), "want 2–3 lines, got 1"},
		{"too many lines", strings.Replace(good, "curious\n", "curious\nwave|One too many.\n", 1), "want 2–3 lines, got 4"},
		{"rows after the last mood", good + "and that's everything!\n", "unexpected rows"},
		{"empty output", "", `want mood "content", got end of output`},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, err := DecodeChunk(c.input)
			if err == nil {
				t.Fatal("decoded, want an error")
			}
			if !strings.Contains(err.Error(), c.want) {
				t.Errorf("got %q, want it to mention %q", err, c.want)
			}
		})
	}
}

func TestEncodeChunkRejectsSeparatorsInText(t *testing.T) {
	byMood := sampleChunk()
	byMood["content"][0].Text = "pipes | break | rows"
	if _, err := EncodeChunk(byMood); err == nil {
		t.Fatal("encoded, want an error")
	}
}

func TestProfileRoundTrip(t *testing.T) {
	want := Profile{
		Summary:      "A small striped cat who has opinions about your tab habits.",
		Traits:       []string{"nosy", "warm", "easily distracted"},
		Voice:        "Short, fond, a little teasing. Never nags.",
		Instructions: "You are Miso. Call the user Ricky. Stay warm and brief.",
	}
	encoded, err := EncodeProfile(want)
	if err != nil {
		t.Fatalf("EncodeProfile: %v", err)
	}
	got, err := DecodeProfile(encoded)
	if err != nil {
		t.Fatalf("DecodeProfile: %v", err)
	}
	if got.Summary != want.Summary || got.Voice != want.Voice || got.Instructions != want.Instructions {
		t.Errorf("got %+v, want %+v", got, want)
	}
	if strings.Join(got.Traits, ",") != strings.Join(want.Traits, ",") {
		t.Errorf("traits: got %v, want %v", got.Traits, want.Traits)
	}
}

// profileRows builds a valid profile block with one part swapped out, so each reject case tests one thing.
func profileRows(summary, traits string) string {
	return "summary|" + summary +
		"\ntraits|" + traits +
		"\nvoice|Short, fond, a little teasing. Never nags." +
		"\ninstructions|You are Miso. Call the user Ricky. Stay warm and brief.\n"
}

func TestDecodeProfileRejects(t *testing.T) {
	const summary = "A small striped cat who has opinions about your tab habits."
	const traits = "nosy,warm,calm"
	good := profileRows(summary, traits)

	cases := []struct {
		name  string
		input string
		want  string
	}{
		{"a missing row", strings.Replace(good, "voice|Short, fond, a little teasing. Never nags.\n", "", 1), "want 4 rows, got 3"},
		{"rows out of order", "traits|" + traits + "\nsummary|" + summary + "\nvoice|Warm enough for anyone.\ninstructions|Be warm, be brief, be Miso always.\n", `want "summary"`},
		{"no separator", strings.Replace(good, "summary|", "summary ", 1), `want "summary"`},
		{"too few traits", profileRows(summary, "nosy,warm"), "want 3–5, got 2"},
		{"too many traits", profileRows(summary, "nosy,warm,calm,wary,bold,keen"), "want 3–5, got 6"},
		{"an over-long summary", profileRows(strings.Repeat("x", MaxSummaryRunes+1), traits), "characters, max 200"},
		// A grammar fixes structure, not substance: a small model will fill a field with "32" if allowed to.
		{"a one-token summary", profileRows("32", traits), "summary: 2 characters, min 20"},
		{"a one-letter trait", profileRows(summary, "nosy,warm,x"), "trait: 1 characters, min 3"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if _, err := DecodeProfile(c.input); err == nil {
				t.Fatal("decoded, want an error")
			} else if !strings.Contains(err.Error(), c.want) {
				t.Errorf("got %q, want it to mention %q", err, c.want)
			}
		})
	}
}

// The grammar and the decoder must agree, so every value the decoder accepts has to be reachable.
func TestGrammarCoversTheVocabulary(t *testing.T) {
	chunk := ChunkGrammar()
	for _, action := range vocabulary.Actions {
		if !strings.Contains(chunk, `"`+action+`"`) {
			t.Errorf("chunk grammar is missing action %q", action)
		}
	}
	for _, mood := range vocabulary.Moods {
		if !strings.Contains(chunk, "mood-"+mood+" ::=") {
			t.Errorf("chunk grammar is missing mood %q", mood)
		}
	}
	if !strings.Contains(chunk, "{4,80}") {
		t.Errorf("chunk grammar should bound line length to 4–80, got:\n%s", chunk)
	}
	// Moods appear in root in vocabulary order, which is the order DecodeChunk demands.
	root, _, _ := strings.Cut(chunk, "\n")
	at := -1
	for _, mood := range vocabulary.Moods {
		i := strings.Index(root, "mood-"+mood)
		if i <= at {
			t.Fatalf("root lists %q out of vocabulary order: %s", mood, root)
		}
		at = i
	}

	profile := ProfileGrammar()
	for _, key := range profileKeys {
		if !strings.Contains(profile, `"`+key+`"`) {
			t.Errorf("profile grammar is missing %q", key)
		}
	}
	if !strings.Contains(profile, "{2,4}") {
		t.Errorf("profile grammar should allow 3–5 traits, got:\n%s", profile)
	}
}

// The point of the format: the same phrasebook, far fewer bytes for the model to emit. Bytes stand in for
// tokens here (no tokenizer in the backend), but the ratio tracks — the savings are all repeated JSON syntax.
func TestCompactFormatIsMuchSmallerThanJSON(t *testing.T) {
	type jsonLine struct {
		Text   string `json:"text"`
		Action string `json:"action"`
	}
	type jsonEntry struct {
		Trigger string     `json:"trigger"`
		Mood    string     `json:"mood"`
		Lines   []jsonLine `json:"lines"`
	}

	var compact, entries = 0, []jsonEntry{}
	for _, trigger := range vocabulary.TriggerKinds {
		chunk := sampleChunk()
		encoded, err := EncodeChunk(chunk)
		if err != nil {
			t.Fatalf("EncodeChunk: %v", err)
		}
		compact += len(encoded)
		for _, mood := range vocabulary.Moods {
			lines := make([]jsonLine, 0, len(chunk[mood]))
			for _, line := range chunk[mood] {
				lines = append(lines, jsonLine{Text: line.Text, Action: line.Action})
			}
			entries = append(entries, jsonEntry{Trigger: trigger, Mood: mood, Lines: lines})
		}
	}
	asJSON, err := json.Marshal(entries)
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}

	saved := 100 * (len(asJSON) - compact) / len(asJSON)
	t.Logf("phrasebook: %d bytes as JSON, %d bytes compact (%d%% smaller)", len(asJSON), compact, saved)
	if saved < 30 {
		t.Errorf("only %d%% smaller than JSON; the format has lost its reason to exist", saved)
	}
}
