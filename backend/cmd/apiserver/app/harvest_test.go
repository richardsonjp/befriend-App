package app

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"befriend/internal/model"
	"befriend/internal/model/enum"
	"befriend/internal/services/personality"
	"befriend/pkg/phrasetable"
	"befriend/pkg/utils/vocabulary"
)

func testQuestions() []model.Question {
	return []model.Question{
		{ID: "friend_name", Type: enum.QUESTION_TEXT, Prompt: "What will you call your friend?", MaxLength: 24},
		{ID: "user_nickname", Type: enum.QUESTION_TEXT, Prompt: "What should your friend call you?", MaxLength: 24},
		{ID: "humor", Type: enum.QUESTION_CHOICE, Prompt: "What kind of humor do you like?",
			Options: []string{"Puns", "Sarcasm", "Wholesome", "Absurd"}},
		{ID: "chattiness", Type: enum.QUESTION_SLIDER, Prompt: "How chatty should your friend be?", Min: 1, Max: 10},
	}
}

// goodProfile and goodChunk stand in for what the Mac's on-device model will produce.
func goodProfile(t *testing.T) string {
	t.Helper()
	encoded, err := phrasetable.EncodeProfile(phrasetable.Profile{
		Summary:      "A small striped cat who has opinions about your tab habits.",
		Traits:       []string{"nosy", "warm", "easily distracted"},
		Voice:        "Short, fond, a little teasing. Never nags.",
		Instructions: "You are Miso. Call the user Ricky. Stay warm, stay brief, stay curious.",
	})
	if err != nil {
		t.Fatalf("EncodeProfile: %v", err)
	}
	return encoded
}

func goodChunk(t *testing.T) string {
	t.Helper()
	byMood := map[string][]phrasetable.Line{}
	for i, mood := range vocabulary.Moods {
		byMood[mood] = []phrasetable.Line{
			{Action: vocabulary.Actions[i%len(vocabulary.Actions)], Text: "Back again already?"},
			{Action: "idle", Text: "I kept your spot warm."},
		}
	}
	encoded, err := phrasetable.EncodeChunk(byMood)
	if err != nil {
		t.Fatalf("EncodeChunk: %v", err)
	}
	return encoded
}

// The whole harvest round trip without a database: prompts out, answers in, only whole passing personalities
// reaching the dataset.
func TestHarvestRoundTrip(t *testing.T) {
	const users = 6
	dir := t.TempDir()
	inputsPath := filepath.Join(dir, "inputs.jsonl")
	outputsPath := filepath.Join(dir, "outputs.jsonl")
	datasetPath := filepath.Join(dir, "dataset.jsonl")

	inputs, err := personality.HarvestInputs(testQuestions(), users, 5)
	if err != nil {
		t.Fatalf("HarvestInputs: %v", err)
	}
	calls, err := writeHarvestInputs(inputs, 5, inputsPath)
	if err != nil {
		t.Fatalf("writeHarvestInputs: %v", err)
	}
	wantCalls := users * (1 + len(vocabulary.TriggerKinds))
	if calls != wantCalls {
		t.Fatalf("wrote %d calls, want %d", calls, wantCalls)
	}

	header, records, err := readInputs(inputsPath)
	if err != nil {
		t.Fatalf("readInputs: %v", err)
	}
	if len(records) != users || header.System == "" || header.ChunkGrammar == "" {
		t.Fatalf("bad inputs file: %d records, header %+v", len(records), header.Count)
	}

	// Answer every call. User 1 gets a broken chunk, user 2 a profile that only survives until cleaning,
	// and user 3 is left half-answered, as an interrupted harvest would leave it.
	file, err := os.Create(outputsPath)
	if err != nil {
		t.Fatalf("create outputs: %v", err)
	}
	writer := bufio.NewWriter(file)
	for i, record := range records {
		for _, call := range record.Calls {
			if i == 3 && call.Kind == personality.KindChunk {
				continue
			}
			output := goodChunk(t)
			switch {
			case call.Kind == personality.KindProfile:
				output = goodProfile(t)
				if i == 2 {
					output = strings.Replace(output, "A small striped cat who has opinions about your tab habits.",
						"Hi"+strings.Repeat("​", phrasetable.MinSummaryRunes), 1)
				}
			case i == 1 && call.Trigger == "poked":
				output = strings.Replace(output, "idle|", "sprint|", 1)
			}
			if err := writeJSONL(writer, harvestOutput{
				ID: record.ID, Kind: call.Kind, Trigger: call.Trigger, Output: output,
			}); err != nil {
				t.Fatalf("write output: %v", err)
			}
		}
	}
	if err := writer.Flush(); err != nil {
		t.Fatalf("flush: %v", err)
	}
	file.Close()

	HarvestFilter(inputsPath, outputsPath, datasetPath)

	samples := readSamples(t, datasetPath)
	// Users 0, 4 and 5 pass whole. User 1 has an invented action, so nothing of it is kept. User 2's profile
	// collapses under cleaning but its chunks are fine, so those six are salvaged. User 3 is incomplete.
	wantSamples := 3*(1+len(vocabulary.TriggerKinds)) + len(vocabulary.TriggerKinds)
	if len(samples) != wantSamples {
		t.Fatalf("got %d samples, want %d", len(samples), wantSamples)
	}
	profiles := 0
	for _, s := range samples {
		if strings.HasSuffix(strings.TrimSpace(s.User), "Write the profile for the friend described by this data.") {
			profiles++
		}
	}
	if profiles != 3 {
		t.Errorf("got %d profile samples, want 3: a rejected profile must not reach the dataset", profiles)
	}
	for _, s := range samples {
		if s.System != header.System {
			t.Error("a sample carries the wrong system message")
		}
		if s.User == "" || s.Output == "" {
			t.Errorf("incomplete sample: %+v", s)
		}
	}
}

func readSamples(t *testing.T, path string) []trainingSample {
	t.Helper()
	file, err := os.Open(path)
	if err != nil {
		t.Fatalf("open dataset: %v", err)
	}
	defer file.Close()

	var samples []trainingSample
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 0, 64*1024), 16*1024*1024)
	for scanner.Scan() {
		var s trainingSample
		if err := json.Unmarshal(scanner.Bytes(), &s); err != nil {
			t.Fatalf("dataset: %v", err)
		}
		samples = append(samples, s)
	}
	return samples
}

// A rerun should be able to correct an earlier answer rather than being blocked by it.
func TestLaterOutputWins(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "outputs.jsonl")
	file, err := os.Create(path)
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	writer := bufio.NewWriter(file)
	for _, output := range []string{"first", "second"} {
		if err := writeJSONL(writer, harvestOutput{ID: "00000", Kind: personality.KindChunk, Trigger: "poked", Output: output}); err != nil {
			t.Fatalf("write: %v", err)
		}
	}
	writer.Flush()
	file.Close()

	byID, err := readOutputs(path)
	if err != nil {
		t.Fatalf("readOutputs: %v", err)
	}
	if got := byID["00000"]; len(got) != 1 || got[0].Output != "second" {
		t.Fatalf("got %+v, want a single 'second'", got)
	}
}
