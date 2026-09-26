package app

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"regexp"
	"sort"
	"strings"

	"befriend/cmd/apiserver/app/store"
	"befriend/internal/services/personality"
	"befriend/pkg/phrasetable"
	"befriend/pkg/utils/vocabulary"
)

// Harvesting training data for befriend's own model (M8).
//
//	apiserver harvest inputs  -n 1200 -o inputs.jsonl   # synthetic users -> prompts, from the live question set
//	  (the Mac tool answers them with Apple's on-device model, writing outputs.jsonl)
//	apiserver harvest filter  --inputs inputs.jsonl --outputs outputs.jsonl -o dataset.jsonl
//
// filter is the gate: a sample only reaches the dataset if the whole personality it belongs to survives the same
// Validate the production worker runs. Grading with the real validator is the reason this is a Go command and not
// a notebook cell.

// harvestHeader is the first line of inputs.jsonl: what's shared by every call. System and ChunkGrammar are the
// built-in skin's; each record carries its own skin's.
type harvestHeader struct {
	System         string `json:"system"`
	ProfileGrammar string `json:"profile_grammar"`
	ChunkGrammar   string `json:"chunk_grammar"`
	Count          int    `json:"count"`
	Seed           uint64 `json:"seed"`
}

// harvestRecord is one synthetic user, the skin its friend wears, and the seven prompts that generate its
// personality (the system message and chunk grammar depend on the skin).
type harvestRecord struct {
	ID           string          `json:"id"`
	Skin         vocabulary.Skin `json:"skin"`
	System       string          `json:"system"`
	ChunkGrammar string          `json:"chunk_grammar"`
	Calls        []harvestCall   `json:"calls"`
}

type harvestCall struct {
	Kind    string `json:"kind"`
	Trigger string `json:"trigger,omitempty"`
	User    string `json:"user"`
}

// harvestOutput is one line of outputs.jsonl, as written by the Mac harvester.
type harvestOutput struct {
	ID      string `json:"id"`
	Kind    string `json:"kind"`
	Trigger string `json:"trigger,omitempty"`
	Output  string `json:"output"`
}

// knownGoodProfile stands in for a rejected one while checking whether a personality's chunks are salvageable.
// Its only job is to pass Validate.
var knownGoodProfile = personality.Personality{
	Summary:      "A small striped cat who has opinions about your tab habits.",
	Traits:       []string{"nosy", "warm", "patient"},
	Voice:        "Short, fond, a little teasing. Never nags.",
	Instructions: "You are Miso. Call the user Ricky. Stay warm, stay brief, stay curious about the work.",
}

// trainingSample is one line of dataset.jsonl: exactly one model call, as it will happen in production. The id
// and kind aren't training inputs; they let the split hold out whole users, so a friend's profile can't sit in
// training while its chunks sit in validation.
type trainingSample struct {
	ID      string `json:"id"`
	Kind    string `json:"kind"`
	Trigger string `json:"trigger,omitempty"`
	System  string `json:"system"`
	User    string `json:"user"`
	Output  string `json:"output"`
}

// HarvestGrammar prints the GBNF a call is generated under, so a served model can be driven by hand:
//
//	apiserver harvest grammar --kind chunk > chunk.gbnf
//	curl localhost:8899/completion -d "$(jq -n --arg g "$(cat chunk.gbnf)" --arg p "$PROMPT" '{prompt:$p,grammar:$g,n_predict:4000}')"
func HarvestGrammar(kind string) {
	switch kind {
	case personality.KindProfile:
		fmt.Print(phrasetable.ProfileGrammar())
	case personality.KindChunk:
		fmt.Print(phrasetable.ChunkGrammar(vocabulary.Default()))
	default:
		exitOnError("harvest grammar", fmt.Errorf("kind must be %q or %q, got %q",
			personality.KindProfile, personality.KindChunk, kind))
	}
}

// HarvestInputs writes the prompts for n synthetic users, using the live question set so the training data
// matches what production will actually ask.
func HarvestInputs(n int, seed uint64, out string) {
	store.Init()
	set, err := store.App.QuestionSetService.GetActive(context.Background())
	exitOnError("harvest inputs", err)

	inputs, err := personality.HarvestInputs(set.Questions.Data, n, seed)
	exitOnError("harvest inputs", err)

	calls, err := writeHarvestInputs(inputs, seed, out)
	exitOnError("harvest inputs", err)
	fmt.Printf("harvest inputs: %d users, %d calls → %s (seed %d, question set v%d)\n",
		len(inputs), calls, out, seed, set.Version)
}

// writeHarvestInputs is the file half of HarvestInputs, split off so the pipeline can be tested without a
// database: only fetching the question set needs one.
func writeHarvestInputs(inputs []personality.PromptInput, seed uint64, out string) (int, error) {
	file, err := os.Create(out)
	if err != nil {
		return 0, err
	}
	defer file.Close()
	writer := bufio.NewWriter(file)

	builtIn := personality.PromptInput{Skin: vocabulary.Default()}
	header := harvestHeader{
		System:         personality.Requests(builtIn)[0].System,
		ProfileGrammar: phrasetable.ProfileGrammar(),
		ChunkGrammar:   phrasetable.ChunkGrammar(vocabulary.Default()),
		Count:          len(inputs),
		Seed:           seed,
	}
	if err := writeJSONL(writer, header); err != nil {
		return 0, err
	}

	calls := 0
	for i, in := range inputs {
		requests := personality.Requests(in)
		record := harvestRecord{
			ID: fmt.Sprintf("%05d", i), Skin: in.Skin.OrDefault(),
			System: requests[0].System, ChunkGrammar: phrasetable.ChunkGrammar(in.Skin),
		}
		for _, request := range requests {
			record.Calls = append(record.Calls, harvestCall{Kind: request.Kind, Trigger: request.Trigger, User: request.User})
		}
		calls += len(record.Calls)
		if err := writeJSONL(writer, record); err != nil {
			return 0, err
		}
	}
	return calls, writer.Flush()
}

// HarvestFilter grades what the Mac produced with the same Validate the production worker runs. A bad chunk
// drops the whole personality — teaching the model that bad chunks are acceptable is the one thing this must not
// do — but a bad profile drops only the profile call, since the six chunk calls stand on their own.
func HarvestFilter(inputsPath, outputsPath, out string) {
	header, records, err := readInputs(inputsPath)
	exitOnError("harvest filter", err)
	outputs, err := readOutputs(outputsPath)
	exitOnError("harvest filter", err)

	file, err := os.Create(out)
	exitOnError("harvest filter", err)
	defer file.Close()
	writer := bufio.NewWriter(file)

	reasons := map[string]int{}
	passed, chunksOnly, samples, incomplete := 0, 0, 0, 0
	for _, record := range records {
		got := outputs[record.ID]
		if len(got) == 0 {
			continue // not answered yet; a harvest is resumable, so this is normal
		}
		profile, chunks, ok := splitOutputs(got)
		if !ok || len(chunks) != len(record.Calls)-1 {
			incomplete++
			continue
		}
		generated, err := personality.Assemble(profile, chunks, record.Skin)
		if err != nil {
			reasons[summarise(err)]++
			continue
		}
		_, _, err = personality.Validate(generated, record.Skin)

		// A bad profile shouldn't waste six good chunks — on this teacher it is the commonest single failure,
		// and the chunk calls don't depend on it. Swapping in a known-good profile and revalidating says whether
		// the chunks were ever the problem, without a second copy of the validation rules to keep in step.
		keepProfile := err == nil
		if err != nil {
			reasons[summarise(err)]++
			probe := *generated
			probe.Personality = knownGoodProfile
			if _, _, retry := personality.Validate(&probe, record.Skin); retry != nil {
				continue // the chunks are bad too: nothing here is worth keeping
			}
			chunksOnly++
		} else {
			passed++
		}
		for _, call := range record.Calls {
			if !keepProfile && call.Kind == personality.KindProfile {
				continue
			}
			sample := trainingSample{
				ID: record.ID, Kind: call.Kind, Trigger: call.Trigger,
				System: systemFor(header, record), User: call.User, Output: outputFor(got, call),
			}
			if sample.Output == "" {
				continue
			}
			exitOnError("harvest filter", writeJSONL(writer, sample))
			samples++
		}
	}
	exitOnError("harvest filter", writer.Flush())

	fmt.Printf("harvest filter: %d personalities passed, %d training samples → %s\n", passed, samples, out)
	if chunksOnly > 0 {
		fmt.Printf("  %d kept for their chunks only (the profile call was rejected)\n", chunksOnly)
	}
	if incomplete > 0 {
		fmt.Printf("  %d part-answered and skipped\n", incomplete)
	}
	if len(reasons) > 0 {
		fmt.Printf("  %d rejected:\n", total(reasons))
		for _, r := range ranked(reasons) {
			fmt.Printf("    %4d  %s\n", reasons[r], r)
		}
	}
}

// systemFor is the record's own system message; inputs written before skins varied share the header's.
func systemFor(header harvestHeader, record harvestRecord) string {
	if record.System != "" {
		return record.System
	}
	return header.System
}

func splitOutputs(got []harvestOutput) (profile string, chunks map[string]string, ok bool) {
	chunks = map[string]string{}
	for _, o := range got {
		if o.Kind == personality.KindProfile {
			profile = o.Output
			continue
		}
		chunks[o.Trigger] = o.Output
	}
	return profile, chunks, profile != ""
}

func outputFor(got []harvestOutput, call harvestCall) string {
	for _, o := range got {
		if o.Kind == call.Kind && o.Trigger == call.Trigger {
			return o.Output
		}
	}
	return ""
}

func readInputs(path string) (harvestHeader, []harvestRecord, error) {
	file, err := os.Open(path)
	if err != nil {
		return harvestHeader{}, nil, err
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 0, 64*1024), 16*1024*1024) // prompts carry the whole <data> block
	if !scanner.Scan() {
		return harvestHeader{}, nil, fmt.Errorf("%s: empty", path)
	}
	var header harvestHeader
	if err := json.Unmarshal(scanner.Bytes(), &header); err != nil {
		return harvestHeader{}, nil, fmt.Errorf("%s: header: %w", path, err)
	}
	var records []harvestRecord
	for scanner.Scan() {
		var record harvestRecord
		if err := json.Unmarshal(scanner.Bytes(), &record); err != nil {
			return harvestHeader{}, nil, fmt.Errorf("%s: %w", path, err)
		}
		records = append(records, record)
	}
	return header, records, scanner.Err()
}

// readOutputs groups the Mac's answers by user. A later answer for the same call wins, so a rerun can correct one.
func readOutputs(path string) (map[string][]harvestOutput, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()

	byID := map[string][]harvestOutput{}
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 0, 64*1024), 16*1024*1024)
	for scanner.Scan() {
		if len(strings.TrimSpace(scanner.Text())) == 0 {
			continue
		}
		var o harvestOutput
		if err := json.Unmarshal(scanner.Bytes(), &o); err != nil {
			return nil, fmt.Errorf("%s: %w", path, err)
		}
		replaced := false
		for i, existing := range byID[o.ID] {
			if existing.Kind == o.Kind && existing.Trigger == o.Trigger {
				byID[o.ID][i], replaced = o, true
				break
			}
		}
		if !replaced {
			byID[o.ID] = append(byID[o.ID], o)
		}
	}
	return byID, scanner.Err()
}

func writeJSONL(writer *bufio.Writer, value interface{}) error {
	encoded, err := json.Marshal(value)
	if err != nil {
		return err
	}
	if _, err := writer.Write(append(encoded, '\n')); err != nil {
		return err
	}
	return nil
}

var (
	quotedValue = regexp.MustCompile(`"[^"]*"`)
	anyNumber   = regexp.MustCompile(`\d+`)
)

// summarise reduces a rejection to what went wrong, dropping where it happened, so the histogram groups by
// problem rather than by slot. Which mood failed is noise; "unknown action" happening 400 times is the signal
// that tells you what the fine-tune has to learn.
func summarise(err error) string {
	segments := strings.Split(err.Error(), ": ")
	for len(segments) > 1 {
		head := segments[0]
		// "phrasebook poked/shy" says both which line and that it is a line; keep only the second part.
		if strings.HasPrefix(head, "phrasebook ") {
			segments[0] = "phrasebook line"
			break
		}
		// Assemble prefixes the trigger, DecodeChunk the row and mood. Both are locations.
		if !vocabulary.IsTriggerKind(head) && head != personality.KindProfile && !strings.HasPrefix(head, "row ") {
			break
		}
		segments = segments[1:]
	}
	message := quotedValue.ReplaceAllString(strings.Join(segments, ": "), "…")
	return anyNumber.ReplaceAllString(message, "N")
}

func total(counts map[string]int) int {
	sum := 0
	for _, n := range counts {
		sum += n
	}
	return sum
}

func ranked(counts map[string]int) []string {
	keys := make([]string, 0, len(counts))
	for k := range counts {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool {
		if counts[keys[i]] != counts[keys[j]] {
			return counts[keys[i]] > counts[keys[j]]
		}
		return keys[i] < keys[j]
	})
	return keys
}
