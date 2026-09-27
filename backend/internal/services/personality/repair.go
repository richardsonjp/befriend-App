package personality

import (
	"strings"
	"unicode/utf8"

	"befriend/pkg/utils/vocabulary"
)

// Repair fixes the slips a free model makes that don't change what it meant, so one overlong sentence or stray
// placeholder doesn't throw away a whole personality and push hatching back by hours. Validate still judges the
// result, and still rejects what can't be repaired (first-person instructions, a trigger with no lines). The
// production worker repairs; harvest grading doesn't, since it keeps the model's raw output as training data.
func Repair(g *Generated, skin vocabulary.Skin) {
	skin = skin.OrDefault()
	g.Summary = shorten(clean(g.Summary), maxSummary)
	g.Voice = shorten(clean(g.Voice), maxVoice)
	g.Instructions = shorten(clean(g.Instructions), maxInstructions)

	var traits []string
	for _, trait := range g.Traits {
		trait = clean(trait)
		if checkText("trait", trait, minTrait, maxTrait, true) == nil {
			traits = append(traits, trait)
		}
	}
	g.Traits = traits[:min(len(traits), maxTraits)]

	seen := map[string]bool{}
	var entries []PhraseEntry
	for _, entry := range g.Phrasebook {
		slot := entry.Trigger + "/" + entry.Mood
		if !vocabulary.IsTriggerKind(entry.Trigger) || !skin.IsMood(entry.Mood) || seen[slot] {
			continue // unknown or repeated: Validate fills the slot from another mood
		}
		seen[slot] = true
		entry.Lines = repairLines(entry.Lines, entry.Trigger, skin)
		if len(entry.Lines) >= minLinesPerSlot {
			entries = append(entries, entry)
		}
	}
	g.Phrasebook = entries
}

func repairLines(lines []PhraseLine, trigger string, skin vocabulary.Skin) []PhraseLine {
	var out []PhraseLine
	for _, line := range lines {
		text := clean(line.Text)
		if trigger != "app_switched" {
			text = strings.ReplaceAll(text, appPlaceholder, "that app") // {app} means nothing outside app switches
		}
		text = shorten(text, maxLineText)
		if hasForeignPlaceholder(text) || checkText("line", text, minLineText, maxLineText, true) != nil {
			continue // a placeholder the apps can't fill, or a line that breaks character
		}
		if duplicate(out, text) {
			continue
		}
		action := line.Action
		if !skin.IsAction(action) {
			action = idleAction
		}
		out = append(out, PhraseLine{Text: text, Action: action})
	}
	return out[:min(len(out), maxLinesPerSlot)]
}

func hasForeignPlaceholder(text string) bool {
	for _, ph := range placeholder.FindAllString(text, -1) {
		if ph != appPlaceholder {
			return true
		}
	}
	return false
}

func duplicate(lines []PhraseLine, text string) bool {
	for _, seen := range lines {
		if strings.EqualFold(seen.Text, text) {
			return true
		}
	}
	return false
}

// shorten keeps text within max runes: at the last sentence end that fits, else the last word, with "…".
func shorten(text string, max int) string {
	if utf8.RuneCountInString(text) <= max {
		return text
	}
	runes := []rune(text)
	cut := string(runes[:max])
	if i := strings.LastIndexAny(cut, ".!?"); i > len(cut)/2 {
		return cut[:i+1]
	}
	cut = string(runes[:max-1])
	if i := strings.LastIndex(cut, " "); i > len(cut)/2 {
		cut = cut[:i]
	}
	return strings.TrimRight(cut, " ,;:-") + "…"
}
