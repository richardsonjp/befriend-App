package personality

import (
	"fmt"
	"regexp"
	"strings"
	"unicode/utf8"

	"befriend/pkg/phrasetable"
	customStr "befriend/pkg/utils/strings"
	"befriend/pkg/utils/vocabulary"
)

// Length caps and counts come from phrasetable, which also builds the grammar the model generates under, so the
// format, the grammar and this validation cannot drift apart.
const (
	maxSummary      = phrasetable.MaxSummaryRunes
	maxVoice        = phrasetable.MaxVoiceRunes
	maxInstructions = phrasetable.MaxInstructionsRunes
	maxTrait        = phrasetable.MaxTraitRunes
	minTraits       = phrasetable.MinTraits
	maxTraits       = phrasetable.MaxTraits
	maxLineText     = phrasetable.MaxTextRunes
	minLinesPerSlot = phrasetable.MinLines
	maxLinesPerSlot = phrasetable.MaxLines
	appPlaceholder  = "{app}"
)

// Personality is the friend's character, shown in the apps and fed to the on-device model.
type Personality struct {
	Summary      string   `json:"summary"`
	Traits       []string `json:"traits"`
	Voice        string   `json:"voice"`
	Instructions string   `json:"instructions"`
}

// PhraseLine is one ready-made reaction used whenever the on-device model can't run.
type PhraseLine struct {
	Text   string `json:"text"`
	Action string `json:"action"`
}

// Phrasebook is phrasebook[trigger kind][mood] -> lines, the shape the apps read.
type Phrasebook map[string]map[string][]PhraseLine

// Generated is the LLM's raw output. The phrasebook comes back as a flat list, which keeps the JSON
// schema small enough for free models; Validate turns it into a Phrasebook.
type Generated struct {
	Personality
	Phrasebook []PhraseEntry `json:"phrasebook"`
}

type PhraseEntry struct {
	Trigger string       `json:"trigger"`
	Mood    string       `json:"mood"`
	Lines   []PhraseLine `json:"lines"`
}

var (
	// User-facing text must never break character.
	breaksCharacter = regexp.MustCompile(`(?i)\b(AI|A\.I\.|artificial intelligence|language model|LLM|chatbot|large language)\b`)
	placeholder     = regexp.MustCompile(`\{[^}]*\}`)
)

// Validate cleans every string (invisible and control characters removed, whitespace collapsed) and
// enforces the contract: length caps, 3–5 traits, every trigger × mood exactly once with 2–3 lines,
// actions from the vocabulary, {app} only for app switches and no other placeholders, and no text that
// breaks character.
func Validate(g *Generated) (*Personality, Phrasebook, error) {
	p := Personality{
		Summary:      clean(g.Summary),
		Voice:        clean(g.Voice),
		Instructions: clean(g.Instructions),
	}
	if err := checkText("summary", p.Summary, maxSummary, true); err != nil {
		return nil, nil, err
	}
	if err := checkText("voice", p.Voice, maxVoice, true); err != nil {
		return nil, nil, err
	}
	// Instructions may legitimately say "never mention being an AI", so they skip the character check.
	if err := checkText("instructions", p.Instructions, maxInstructions, false); err != nil {
		return nil, nil, err
	}
	if len(g.Traits) < minTraits || len(g.Traits) > maxTraits {
		return nil, nil, fmt.Errorf("traits: want %d–%d, got %d", minTraits, maxTraits, len(g.Traits))
	}
	for _, trait := range g.Traits {
		trait = clean(trait)
		if err := checkText("trait", trait, maxTrait, true); err != nil {
			return nil, nil, err
		}
		p.Traits = append(p.Traits, trait)
	}

	book := Phrasebook{}
	for _, entry := range g.Phrasebook {
		slot := entry.Trigger + "/" + entry.Mood
		if !vocabulary.IsTriggerKind(entry.Trigger) || !vocabulary.IsMood(entry.Mood) {
			return nil, nil, fmt.Errorf("phrasebook %s: unknown trigger or mood", slot)
		}
		if _, dup := book[entry.Trigger][entry.Mood]; dup {
			return nil, nil, fmt.Errorf("phrasebook %s: listed more than once", slot)
		}
		if len(entry.Lines) < minLinesPerSlot || len(entry.Lines) > maxLinesPerSlot {
			return nil, nil, fmt.Errorf("phrasebook %s: want %d–%d lines, got %d", slot, minLinesPerSlot, maxLinesPerSlot, len(entry.Lines))
		}
		lines := make([]PhraseLine, 0, len(entry.Lines))
		for _, line := range entry.Lines {
			text := clean(line.Text)
			if err := checkText("phrasebook "+slot, text, maxLineText, true); err != nil {
				return nil, nil, err
			}
			if !vocabulary.IsAction(line.Action) {
				return nil, nil, fmt.Errorf("phrasebook %s: unknown action %q", slot, line.Action)
			}
			for _, ph := range placeholder.FindAllString(text, -1) {
				if ph != appPlaceholder || entry.Trigger != "app_switched" {
					return nil, nil, fmt.Errorf("phrasebook %s: placeholder %s not allowed here", slot, ph)
				}
			}
			lines = append(lines, PhraseLine{Text: text, Action: line.Action})
		}
		if book[entry.Trigger] == nil {
			book[entry.Trigger] = map[string][]PhraseLine{}
		}
		book[entry.Trigger][entry.Mood] = lines
	}
	for _, trigger := range vocabulary.TriggerKinds {
		for _, mood := range vocabulary.Moods {
			if _, ok := book[trigger][mood]; !ok {
				return nil, nil, fmt.Errorf("phrasebook %s/%s: missing", trigger, mood)
			}
		}
	}
	return &p, book, nil
}

// clean strips invisible and control characters (LLM output is repaired, not rejected, for these) and
// collapses all whitespace, including newlines, to single spaces.
func clean(s string) string {
	s = strings.Map(func(r rune) rune {
		if customStr.IsHiddenRune(r) {
			return -1
		}
		return r
	}, s)
	return strings.Join(strings.Fields(s), " ")
}

func checkText(field, s string, max int, userFacing bool) error {
	if s == "" {
		return fmt.Errorf("%s: empty", field)
	}
	if n := utf8.RuneCountInString(s); n > max {
		return fmt.Errorf("%s: %d characters, max %d", field, n, max)
	}
	if userFacing && breaksCharacter.MatchString(s) {
		return fmt.Errorf("%s: mentions being an AI", field)
	}
	return nil
}
