// Package phrasetable encodes a friend's personality and phrasebook as compact text rows instead of JSON.
//
// The phrasebook is a fixed grid — every trigger kind crossed with every mood — so neither key is ever written
// down: a request asks for one trigger, and the moods come back in vocabulary order. That drops roughly a third
// of the model's output tokens, which is what makes a small self-hosted model fast enough to hatch a friend.
//
// The grammar in grammar.go is built from the same tables, so a missing mood, an invented action or an
// over-long line cannot be generated at all. Decode re-checks the same rules, because a grammar only binds the
// model we serve ourselves; content rules (character breaks, placeholders, cleaning) stay in personality.Validate.
package phrasetable

import (
	"fmt"
	"strconv"
	"strings"
	"unicode/utf8"

	"befriend/pkg/utils/vocabulary"
)

// Limits are the contract shared by the grammar, the decoder and personality.Validate. Instructions stay short
// because the on-device model carries them inside its 4K context.
const (
	MinLines             = 2
	MaxLines             = 3
	MaxTextRunes         = 80
	MinTraits            = 3
	MaxTraits            = 5
	MaxTraitRunes        = 24
	MaxSummaryRunes      = 200
	MaxVoiceRunes        = 160
	MaxInstructionsRunes = 600
)

// Minimums, enforced by the grammar as well as here. A grammar only fixes structure, so a small model is free to
// satisfy it with nothing: a 135M model asked for a profile answered "summary|32". A one-word personality is
// worse than a failed generation, because a failure retries and this would be saved.
const (
	MinTextRunes         = 4
	MinTraitRunes        = 3
	MinSummaryRunes      = 20
	MinVoiceRunes        = 20
	MinInstructionsRunes = 40
)

// sep divides a row's key from its value. It never appears in an action, a mood or a field name, so the first
// one splits the row; later ones are ordinary text.
const sep = "|"

// profileKeys are the profile's rows, in the order the grammar emits them.
var profileKeys = []string{"summary", "traits", "voice", "instructions"}

// Line is one phrasebook line: what the friend says and the action it plays.
type Line struct {
	Action string
	Text   string
}

// Profile is the friend's character block, the non-phrasebook half of a generation.
type Profile struct {
	Summary      string
	Traits       []string
	Voice        string
	Instructions string
}

// EncodeChunk writes one trigger's block: each mood on its own row, followed by its "action|text" lines.
// Used to turn harvested training data into the format the model is trained to produce.
func EncodeChunk(byMood map[string][]Line) (string, error) {
	var b strings.Builder
	for _, mood := range vocabulary.Moods {
		lines := byMood[mood]
		if len(lines) < MinLines || len(lines) > MaxLines {
			return "", fmt.Errorf("%s: want %d–%d lines, got %d", mood, MinLines, MaxLines, len(lines))
		}
		b.WriteString(mood)
		b.WriteString("\n")
		for _, line := range lines {
			if err := checkLine(line); err != nil {
				return "", fmt.Errorf("%s: %w", mood, err)
			}
			b.WriteString(line.Action)
			b.WriteString(sep)
			b.WriteString(line.Text)
			b.WriteString("\n")
		}
	}
	return b.String(), nil
}

// DecodeChunk reads one trigger's block back. It requires every mood, in vocabulary order, with nothing left over.
func DecodeChunk(s string) (map[string][]Line, error) {
	rows := splitRows(s)
	out := make(map[string][]Line, len(vocabulary.Moods))
	i := 0
	for _, mood := range vocabulary.Moods {
		if i >= len(rows) || rows[i] != mood {
			return nil, fmt.Errorf("row %d: want mood %q, got %s", i+1, mood, describe(rows, i))
		}
		i++
		var lines []Line
		for i < len(rows) && strings.Contains(rows[i], sep) {
			line, err := parseLine(rows[i])
			if err != nil {
				return nil, fmt.Errorf("row %d (%s): %w", i+1, mood, err)
			}
			lines = append(lines, line)
			i++
		}
		if len(lines) < MinLines || len(lines) > MaxLines {
			return nil, fmt.Errorf("%s: want %d–%d lines, got %d", mood, MinLines, MaxLines, len(lines))
		}
		out[mood] = lines
	}
	if i < len(rows) {
		return nil, fmt.Errorf("row %d: %d unexpected rows after the last mood", i+1, len(rows)-i)
	}
	return out, nil
}

// EncodeProfile writes the character block as one "key|value" row per field.
func EncodeProfile(p Profile) (string, error) {
	if len(p.Traits) < MinTraits || len(p.Traits) > MaxTraits {
		return "", fmt.Errorf("traits: want %d–%d, got %d", MinTraits, MaxTraits, len(p.Traits))
	}
	for _, trait := range p.Traits {
		if strings.ContainsAny(trait, ",|\n") {
			return "", fmt.Errorf("trait %q: contains a separator", trait)
		}
		if err := checkRunes("trait", trait, MinTraitRunes, MaxTraitRunes); err != nil {
			return "", err
		}
	}
	values := map[string]string{
		"summary":      p.Summary,
		"traits":       strings.Join(p.Traits, ","),
		"voice":        p.Voice,
		"instructions": p.Instructions,
	}
	var b strings.Builder
	for _, key := range profileKeys {
		if strings.Contains(values[key], "\n") {
			return "", fmt.Errorf("%s: contains a newline", key)
		}
		min, max := bounds(key)
		if err := checkRunes(key, values[key], min, max); err != nil {
			return "", err
		}
		b.WriteString(key)
		b.WriteString(sep)
		b.WriteString(values[key])
		b.WriteString("\n")
	}
	return b.String(), nil
}

// DecodeProfile reads the character block back, requiring all four rows in order.
func DecodeProfile(s string) (Profile, error) {
	rows := splitRows(s)
	if len(rows) != len(profileKeys) {
		return Profile{}, fmt.Errorf("want %d rows, got %d", len(profileKeys), len(rows))
	}
	values := make(map[string]string, len(profileKeys))
	for i, key := range profileKeys {
		got, value, ok := strings.Cut(rows[i], sep)
		if !ok || got != key {
			return Profile{}, fmt.Errorf("row %d: want %q, got %s", i+1, key, strconv.Quote(rows[i]))
		}
		min, max := bounds(key)
		if err := checkRunes(key, value, min, max); err != nil {
			return Profile{}, err
		}
		values[key] = value
	}
	traits := strings.Split(values["traits"], ",")
	if len(traits) < MinTraits || len(traits) > MaxTraits {
		return Profile{}, fmt.Errorf("traits: want %d–%d, got %d", MinTraits, MaxTraits, len(traits))
	}
	for _, trait := range traits {
		if err := checkRunes("trait", trait, MinTraitRunes, MaxTraitRunes); err != nil {
			return Profile{}, err
		}
	}
	return Profile{
		Summary:      values["summary"],
		Traits:       traits,
		Voice:        values["voice"],
		Instructions: values["instructions"],
	}, nil
}

// bounds is the length range for a profile row's value.
func bounds(key string) (min, max int) {
	switch key {
	case "summary":
		return MinSummaryRunes, MaxSummaryRunes
	case "voice":
		return MinVoiceRunes, MaxVoiceRunes
	case "instructions":
		return MinInstructionsRunes, MaxInstructionsRunes
	default:
		// traits, as one joined string. Deliberately looser than the grammar — the real check is per trait,
		// once split — so don't "tighten" this to match: it would start rejecting valid comma spacing.
		return MinTraits * MinTraitRunes, MaxTraits * (MaxTraitRunes + 1)
	}
}

func parseLine(row string) (Line, error) {
	action, text, _ := strings.Cut(row, sep)
	if !vocabulary.IsAction(action) {
		return Line{}, fmt.Errorf("unknown action %q", action)
	}
	line := Line{Action: action, Text: text}
	return line, checkLine(line)
}

func checkLine(line Line) error {
	if !vocabulary.IsAction(line.Action) {
		return fmt.Errorf("unknown action %q", line.Action)
	}
	if strings.ContainsAny(line.Text, sep+"\n") {
		return fmt.Errorf("text %q: contains a separator", line.Text)
	}
	return checkRunes("text", line.Text, MinTextRunes, MaxTextRunes)
}

func checkRunes(field, s string, min, max int) error {
	if s == "" {
		return fmt.Errorf("%s: empty", field)
	}
	switch n := utf8.RuneCountInString(s); {
	case n > max:
		return fmt.Errorf("%s: %d characters, max %d", field, n, max)
	case n < min:
		return fmt.Errorf("%s: %d characters, min %d", field, n, min)
	}
	return nil
}

// splitRows drops carriage returns and blank rows, so a model that pads with a trailing newline still parses.
func splitRows(s string) []string {
	var rows []string
	for _, row := range strings.Split(s, "\n") {
		if row = strings.TrimRight(row, "\r"); row != "" {
			rows = append(rows, row)
		}
	}
	return rows
}

func describe(rows []string, i int) string {
	if i >= len(rows) {
		return "end of output"
	}
	return strconv.Quote(rows[i])
}
