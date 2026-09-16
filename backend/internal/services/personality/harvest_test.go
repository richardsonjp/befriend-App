package personality

import (
	"strings"
	"testing"

	"befriend/internal/model"
	"befriend/internal/model/enum"
	"befriend/pkg/phrasetable"
	"befriend/pkg/utils/vocabulary"
)

// questionSetV1 mirrors the seeded set in migration 000003 closely enough to exercise every question type.
func questionSetV1() []model.Question {
	return []model.Question{
		{ID: "friend_name", Type: enum.QUESTION_TEXT, Prompt: "What will you call your friend?", MaxLength: 24},
		{ID: "user_nickname", Type: enum.QUESTION_TEXT, Prompt: "What should your friend call you?", MaxLength: 24},
		{ID: "best_time", Type: enum.QUESTION_CHOICE, Prompt: "When do you feel most like yourself?",
			Options: []string{"Morning", "Afternoon", "Evening", "Late night"}},
		{ID: "energy", Type: enum.QUESTION_SLIDER, Prompt: "What energy should your friend have?", Min: 1, Max: 10},
		{ID: "humor", Type: enum.QUESTION_CHOICE, Prompt: "What kind of humor do you like?",
			Options: []string{"Puns", "Sarcasm", "Wholesome", "Absurd"}},
	}
}

func TestHarvestInputsAreDistinctAndRepeatable(t *testing.T) {
	questions := questionSetV1()
	inputs, err := HarvestInputs(questions, 200, 42)
	if err != nil {
		t.Fatalf("HarvestInputs: %v", err)
	}
	if len(inputs) != 200 {
		t.Fatalf("got %d inputs, want 200", len(inputs))
	}

	seen := map[string]bool{}
	for _, in := range inputs {
		key := harvestKey(in)
		if seen[key] {
			t.Fatalf("duplicate input: %s", key)
		}
		seen[key] = true

		if len(in.Answers) != len(questions) {
			t.Fatalf("got %d answers, want %d", len(in.Answers), len(questions))
		}
		if in.FriendName == "" || in.UserNickname == "" || in.BirthCity == "" {
			t.Fatalf("incomplete input: %+v", in)
		}
		if in.Chart.WesternSign == "" || in.Chart.ChineseAnimal == "" || in.Chart.FengShuiStar == 0 {
			t.Fatalf("incomplete chart: %+v", in.Chart)
		}
		// The two text answers must agree with the top-level fields: the prompt states both.
		if in.Answers[0].Answer != in.FriendName || in.Answers[1].Answer != in.UserNickname {
			t.Fatalf("name answers disagree with the input: %+v", in)
		}
	}

	// Same seed, same inputs — a harvest can be extended without re-answering what the Mac already did.
	again, err := HarvestInputs(questions, 200, 42)
	if err != nil {
		t.Fatalf("HarvestInputs: %v", err)
	}
	for i := range inputs {
		if harvestKey(inputs[i]) != harvestKey(again[i]) {
			t.Fatalf("input %d differs between runs with the same seed", i)
		}
	}
}

// The fine-tune learns to ignore any option it never sees, so coverage is the whole point of the sampler.
func TestHarvestInputsCoverEveryOption(t *testing.T) {
	questions := questionSetV1()
	inputs, err := HarvestInputs(questions, 400, 7)
	if err != nil {
		t.Fatalf("HarvestInputs: %v", err)
	}
	seen := map[string]map[interface{}]bool{}
	for _, in := range inputs {
		for _, a := range in.Answers {
			if seen[a.Question] == nil {
				seen[a.Question] = map[interface{}]bool{}
			}
			seen[a.Question][a.Answer] = true
		}
	}
	for _, q := range questions {
		switch q.Type {
		case enum.QUESTION_CHOICE:
			for _, option := range q.Options {
				if !seen[q.Prompt][option] {
					t.Errorf("%q: option %q never appeared", q.ID, option)
				}
			}
		case enum.QUESTION_SLIDER:
			if n := len(seen[q.Prompt]); n != q.Max-q.Min+1 {
				t.Errorf("%q: %d of %d slider values appeared", q.ID, n, q.Max-q.Min+1)
			}
		}
	}
}

func TestHarvestInputsRejectsNonsense(t *testing.T) {
	if _, err := HarvestInputs(questionSetV1(), 0, 1); err == nil {
		t.Error("n=0 was accepted")
	}
	if _, err := HarvestInputs(nil, 10, 1); err == nil {
		t.Error("an empty question set was accepted")
	}
	// A set with only one possible answer can't yield two distinct inputs, and must say so rather than hang.
	tiny := []model.Question{{ID: "only", Type: enum.QUESTION_CHOICE, Prompt: "?", Options: []string{"yes"}}}
	if _, err := HarvestInputs(tiny, 100_000, 1); err == nil {
		t.Error("an impossible request was accepted")
	}
}

func TestRequestsShareACacheablePrefix(t *testing.T) {
	inputs, err := HarvestInputs(questionSetV1(), 1, 3)
	if err != nil {
		t.Fatalf("HarvestInputs: %v", err)
	}
	requests := Requests(inputs[0])
	if len(requests) != 1+len(vocabulary.TriggerKinds) {
		t.Fatalf("got %d requests, want %d", len(requests), 1+len(vocabulary.TriggerKinds))
	}
	if requests[0].Kind != KindProfile {
		t.Errorf("the profile should come first, got %q", requests[0].Kind)
	}

	// Every call shares the system message and the <data> block; only the trailing ask differs. That is what
	// lets llama.cpp reuse the prefix across all seven, and keeps the fine-tune's inputs consistent.
	data := requests[0].User[:strings.Index(requests[0].User, "</data>")]
	for _, r := range requests[1:] {
		if r.System != requests[0].System {
			t.Fatal("system messages differ between calls")
		}
		if !strings.HasPrefix(r.User, data) {
			t.Fatalf("%s: user message does not share the data prefix", r.Trigger)
		}
		if !strings.Contains(r.User[len(data):], "Write this friend's lines for one moment: "+r.Trigger) {
			t.Fatalf("%s: the ask should come last: %q", r.Trigger, r.User)
		}
	}
	if requests[1].Grammar() != phrasetable.ChunkGrammar() || requests[0].Grammar() != phrasetable.ProfileGrammar() {
		t.Error("requests carry the wrong grammar")
	}
}

func TestAssembleFeedsValidate(t *testing.T) {
	profile, err := phrasetable.EncodeProfile(phrasetable.Profile{
		Summary:      "A small striped cat who has opinions about your tab habits.",
		Traits:       []string{"nosy", "warm", "easily distracted"},
		Voice:        "Short, fond, a little teasing. Never nags.",
		Instructions: "You are Miso. Call the user Ricky. Stay warm, stay brief, stay curious.",
	})
	if err != nil {
		t.Fatalf("EncodeProfile: %v", err)
	}

	chunks := map[string]string{}
	for _, trigger := range vocabulary.TriggerKinds {
		byMood := map[string][]phrasetable.Line{}
		for i, mood := range vocabulary.Moods {
			byMood[mood] = []phrasetable.Line{
				{Action: vocabulary.Actions[i%len(vocabulary.Actions)], Text: "Back again already?"},
				{Action: "idle", Text: "I kept your spot warm."},
			}
		}
		encoded, err := phrasetable.EncodeChunk(byMood)
		if err != nil {
			t.Fatalf("EncodeChunk %s: %v", trigger, err)
		}
		chunks[trigger] = encoded
	}

	generated, err := Assemble(profile, chunks)
	if err != nil {
		t.Fatalf("Assemble: %v", err)
	}
	if _, book, err := Validate(generated); err != nil {
		t.Fatalf("Validate: %v", err)
	} else if len(book) != len(vocabulary.TriggerKinds) {
		t.Fatalf("got %d triggers, want %d", len(book), len(vocabulary.TriggerKinds))
	}

	// A single missing chunk fails the whole personality, so a part-harvested user never reaches the dataset.
	delete(chunks, "poked")
	if _, err := Assemble(profile, chunks); err == nil {
		t.Error("a missing chunk was accepted")
	}
}
