package personality

import (
	"strings"
	"testing"

	"befriend/pkg/utils/vocabulary"
)

// ghost has plain idle and jump, stomp only when grumpy, and float only when happy.
var ghost = vocabulary.FromClips([]string{"idle", "walk", "jump", "focus", "idle/grumpy", "stomp/grumpy", "float/happy"})

func ghostGenerated() *Generated {
	g := validGenerated()
	g.Phrasebook = nil
	for _, trigger := range vocabulary.TriggerKinds {
		for _, mood := range ghost.Moods {
			g.Phrasebook = append(g.Phrasebook, PhraseEntry{Trigger: trigger, Mood: mood,
				Lines: []PhraseLine{{Text: "Boo, hello!", Action: "jump"}, {Text: "Mhm, sure.", Action: "idle"}}})
		}
	}
	return g
}

func TestValidateForASkin(t *testing.T) {
	g := ghostGenerated()
	g.Phrasebook[0].Lines[0].Action = "float" // drawn only happy; the first entry is grumpy
	g.Phrasebook[1].Lines[0].Action = "float" // happy
	_, book, err := Validate(g, ghost)
	if err != nil {
		t.Fatal(err)
	}
	trigger := vocabulary.TriggerKinds[0]
	if got := book[trigger]["grumpy"][0].Action; got != "idle" {
		t.Errorf("float in grumpy = %q; want it repaired to idle", got)
	}
	if got := book[trigger]["happy"][0].Action; got != "float" {
		t.Errorf("float in happy = %q", got)
	}

	for name, mutate := range map[string]func(g *Generated){
		"an action the skin doesn't have": func(g *Generated) { g.Phrasebook[0].Lines[0].Action = "wave" },
		"an app-played clip":              func(g *Generated) { g.Phrasebook[0].Lines[0].Action = "walk" },
		"a mood the skin doesn't have":    func(g *Generated) { g.Phrasebook[0].Mood = "content" },
		"a missing mood":                  func(g *Generated) { g.Phrasebook = g.Phrasebook[1:] },
	} {
		g := ghostGenerated()
		mutate(g)
		if _, _, err := Validate(g, ghost); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}

func TestPromptForASkin(t *testing.T) {
	system, _ := Prompt(PromptInput{FriendName: "Boo", Skin: ghost})
	for _, want := range []string{"Moods: grumpy, happy", "- grumpy: idle, jump, stomp", "- happy: float, idle, jump"} {
		if !strings.Contains(system, want) {
			t.Errorf("prompt lacks %q", want)
		}
	}
	if strings.Contains(system, "walk") || strings.Contains(system, "celebrate") {
		t.Error("prompt offers actions the skin can't play")
	}

	schema := ResponseSchema(ghost)
	entry := schema["properties"].(map[string]interface{})["phrasebook"].(map[string]interface{})["items"].(map[string]interface{})
	moods := entry["properties"].(map[string]interface{})["mood"].(map[string]interface{})["enum"].([]string)
	if strings.Join(moods, ",") != "grumpy,happy" {
		t.Errorf("schema moods = %v", moods)
	}
}

func TestReskinPromptKeepsThePersonality(t *testing.T) {
	previous := validGenerated().Personality
	system, user := Prompt(PromptInput{FriendName: "Boo", Skin: ghost, Previous: &previous, Reskin: true})
	if !strings.Contains(system, "changing its look") || !strings.Contains(user, previous.Summary) {
		t.Error("a reskin prompt carries the personality and asks to keep it")
	}
	if strings.Contains(system, "weekly evolution") || strings.Contains(user, "recent_activity") {
		t.Error("a reskin isn't an evolution")
	}
}
