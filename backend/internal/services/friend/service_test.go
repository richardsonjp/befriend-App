package friend

import (
	"encoding/json"
	"testing"
)

func TestPhrasebookEntries(t *testing.T) {
	stored := json.RawMessage(`{"poked":{"very_happy":[{"text":"Hi!","action":"float"}]},"app_switched":{"grumpy":[]}}`)
	got, err := phrasebookEntries(stored)
	if err != nil {
		t.Fatal(err)
	}
	want := `[{"trigger":"app_switched","mood":"grumpy","lines":[]},{"trigger":"poked","mood":"very_happy","lines":[{"text":"Hi!","action":"float"}]}]`
	if string(got) != want {
		t.Errorf("entries = %s", got)
	}
}
