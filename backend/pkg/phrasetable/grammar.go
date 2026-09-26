package phrasetable

import (
	"fmt"
	"strings"

	"befriend/pkg/utils/vocabulary"
)

// GBNF grammars for llama.cpp's /completion endpoint. Generated from the same vocabulary tables the decoder
// checks against, so the two can never drift: what the grammar permits is exactly what DecodeChunk accepts.
//
// Constraining generation instead of validating it afterwards removes the failure modes that make a small model
// unusable here — a skipped mood, an invented action, a run-on line — and leaves only the writing to judge.

// ChunkGrammar constrains one trigger's block: every mood of the skin in order, each with 2–3 lines of actions
// drawn for that mood. The zero Skin is the built-in one, whose grammar is unchanged from vocabulary v1.
func ChunkGrammar(skin vocabulary.Skin) string {
	skin = skin.OrDefault()
	if skin.Uniform() {
		return uniformChunkGrammar(skin)
	}
	// Moods with their own actions get their own rules, named by position: mood names aren't valid rule names.
	var b strings.Builder
	roots := make([]string, 0, len(skin.Moods))
	for i := range skin.Moods {
		roots = append(roots, fmt.Sprintf("mood-%d", i))
	}
	fmt.Fprintf(&b, "root ::= %s\n", strings.Join(roots, " "))
	for i, mood := range skin.Moods {
		line := fmt.Sprintf("line-%d", i)
		slot := strings.TrimSpace(strings.Repeat(line+" ", MinLines) + strings.Repeat(line+"? ", MaxLines-MinLines))
		fmt.Fprintf(&b, "mood-%d ::= %q \"\\n\" %s\n", i, mood, slot)
		fmt.Fprintf(&b, "%s ::= action-%d %q text \"\\n\"\n", line, i, sep)
		fmt.Fprintf(&b, "action-%d ::= %s\n", i, alternatives(skin.ActionsFor(mood)))
	}
	fmt.Fprintf(&b, "text ::= [^%s\\n]{%d,%d}\n", sep, MinTextRunes, MaxTextRunes)
	return b.String()
}

func uniformChunkGrammar(skin vocabulary.Skin) string {
	var b strings.Builder

	roots := make([]string, 0, len(skin.Moods))
	for _, mood := range skin.Moods {
		roots = append(roots, "mood-"+ruleName(mood))
	}
	fmt.Fprintf(&b, "root ::= %s\n", strings.Join(roots, " "))

	// Two required lines then one optional: the caps are small and literal, which keeps the grammar readable.
	slot := strings.TrimSpace(strings.Repeat("line ", MinLines) + strings.Repeat("line? ", MaxLines-MinLines))
	for _, mood := range skin.Moods {
		fmt.Fprintf(&b, "mood-%s ::= %q \"\\n\" %s\n", ruleName(mood), mood, slot)
	}

	fmt.Fprintf(&b, "line ::= action %q text \"\\n\"\n", sep)
	fmt.Fprintf(&b, "action ::= %s\n", alternatives(skin.Actions()))
	fmt.Fprintf(&b, "text ::= [^%s\\n]{%d,%d}\n", sep, MinTextRunes, MaxTextRunes)
	return b.String()
}

// ruleName makes a mood usable in a GBNF rule name, which allows letters, digits and dashes. It relies on mood
// names being skinpack.NamePattern (a-z, 0-9, _); loosen that and this must escape more.
func ruleName(mood string) string {
	return strings.ReplaceAll(mood, "_", "-")
}

// ProfileGrammar constrains the character block: four keyed rows in a fixed order.
func ProfileGrammar() string {
	var b strings.Builder

	rows := make([]string, 0, len(profileKeys))
	for _, key := range profileKeys {
		rows = append(rows, fmt.Sprintf("%q %q %s-value \"\\n\"", key, sep, key))
	}
	fmt.Fprintf(&b, "root ::= %s\n", strings.Join(rows, " "))

	fmt.Fprintf(&b, "summary-value ::= [^\\n]{%d,%d}\n", MinSummaryRunes, MaxSummaryRunes)
	fmt.Fprintf(&b, "voice-value ::= [^\\n]{%d,%d}\n", MinVoiceRunes, MaxVoiceRunes)
	fmt.Fprintf(&b, "instructions-value ::= [^\\n]{%d,%d}\n", MinInstructionsRunes, MaxInstructionsRunes)
	fmt.Fprintf(&b, "traits-value ::= trait (\",\" trait){%d,%d}\n", MinTraits-1, MaxTraits-1)
	fmt.Fprintf(&b, "trait ::= [^,%s\\n]{%d,%d}\n", sep, MinTraitRunes, MaxTraitRunes)
	return b.String()
}

func alternatives(values []string) string {
	quoted := make([]string, 0, len(values))
	for _, v := range values {
		quoted = append(quoted, fmt.Sprintf("%q", v))
	}
	return strings.Join(quoted, " | ")
}
