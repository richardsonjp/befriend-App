package chat_sync

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"befriend/internal/model"
	"befriend/pkg/utils/errors"
	"befriend/pkg/utils/validator"
)

func TestBuildRecord(t *testing.T) {
	at := time.Date(2026, 10, 1, 9, 30, 0, 123456789, time.FixedZone("WIB", 7*3600))
	payload := RecordPayload{UserID: "u", Kind: "conversation", ID: "00000000-0000-4000-8000-000000000001", ModifiedAt: at, Blob: []byte("cipher")}

	m, err := buildRecord(payload)
	if err != nil {
		t.Fatal(err)
	}
	if m.Size != 6 || string(m.Blob) != "cipher" || m.Deleted {
		t.Errorf("record = %+v", m)
	}
	if want := at.UTC().Truncate(time.Microsecond); !m.ModifiedAt.Equal(want) || m.ModifiedAt.Location() != time.UTC {
		t.Errorf("modified_at = %v; want %v (UTC, microseconds)", m.ModifiedAt, want)
	}

	tomb := payload
	tomb.Deleted = true
	if m, err := buildRecord(tomb); err != nil || m.Blob != nil || m.Size != 0 || !m.Deleted {
		t.Errorf("tombstone = %+v, %v; want no blob, size 0", m, err)
	}

	missing := payload
	missing.Blob = nil
	if _, err := buildRecord(missing); !errors.Is(err, "VALIDATION_FAILED") {
		t.Errorf("missing blob: %v", err)
	}

	atLimit := payload
	atLimit.Blob = make([]byte, MaxBlobSize)
	if _, err := buildRecord(atLimit); err != nil {
		t.Errorf("2 MiB blob rejected: %v", err)
	}
	tooBig := payload
	tooBig.Blob = make([]byte, MaxBlobSize+1)
	_, err = buildRecord(tooBig)
	if !errors.Is(err, "CHAT_RECORD_TOO_LARGE") || errors.From("CHAT_RECORD_TOO_LARGE").Status != 413 {
		t.Errorf("oversized blob: %v", err)
	}
}

func TestBuildPage(t *testing.T) {
	at := time.Date(2026, 10, 1, 2, 30, 0, 0, time.UTC)
	rows := []model.ChatRecord{
		{Kind: "conversation", RecordID: "a", Seq: 11, ModifiedAt: at, Blob: []byte{1, 2}},
		{Kind: "document", RecordID: "b", Seq: 12, ModifiedAt: at, Deleted: true},
		{Kind: "conversation", RecordID: "c", Seq: 15, ModifiedAt: at, Blob: []byte{3}},
	}

	page := buildPage(rows, 10, 2) // limit+1 rows: another page follows
	if !page.More || page.Next != 12 || len(page.Records) != 2 {
		t.Fatalf("page = %+v; want 2 records, next 12, more", page)
	}
	if page.Records[0].ModifiedAt != "2026-10-01T02:30:00.000000Z" {
		t.Errorf("modified_at = %q", page.Records[0].ModifiedAt)
	}

	raw, _ := json.Marshal(page)
	got := string(raw)
	if !strings.Contains(got, `"blob":"AQI="`) || strings.Count(got, `"blob"`) != 1 {
		t.Errorf("JSON = %s; want base64 blob on the live record, none on the tombstone", got)
	}

	last := buildPage(rows[2:], 12, 2)
	if last.More || last.Next != 15 {
		t.Errorf("last page = %+v", last)
	}
	empty := buildPage(nil, 15, 100)
	if empty.More || empty.Next != 15 || empty.Records == nil {
		t.Errorf("empty page = %+v; want next = after and [] records", empty)
	}
}

func TestMergeExchange(t *testing.T) {
	macKey := "bWFj"
	stored := model.ChatKeyExchange{ID: "x", UserID: "u", MacPublic: &macKey}

	merged, changed, err := mergeExchange(stored, ExchangePayload{PhonePublic: "cGhvbmU="})
	if err != nil || !changed || *merged.PhonePublic != "cGhvbmU=" || *merged.MacPublic != macKey {
		t.Fatalf("merge = %+v, %v, %v", merged, changed, err)
	}
	if stored.PhonePublic != nil {
		t.Error("merge changed the stored exchange")
	}

	if _, changed, err := mergeExchange(merged, ExchangePayload{MacPublic: macKey}); err != nil || changed {
		t.Errorf("resending the same value: changed %v, %v", changed, err)
	}
	if _, _, err := mergeExchange(merged, ExchangePayload{MacPublic: "b3RoZXI="}); !errors.Is(err, "CHAT_EXCHANGE_CONFLICT") {
		t.Errorf("overwrite: %v; want CHAT_EXCHANGE_CONFLICT", err)
	}
}

func TestPayloadDecoding(t *testing.T) {
	var p RecordPayload
	body := `{"modified_at":"2026-10-01T09:30:00.123456Z","deleted":false,"blob":"AAEC"}`
	if err := json.Unmarshal([]byte(body), &p); err != nil || len(p.Blob) != 3 {
		t.Fatalf("decode = %+v, %v", p, err)
	}
	if err := json.Unmarshal([]byte(`{"blob":"not base64!"}`), &p); err == nil {
		t.Error("invalid base64 accepted")
	}

	p.Kind, p.ID = "conversation", "00000000-0000-4000-8000-000000000001"
	if _, err := validator.Validate(&p); err != nil {
		t.Errorf("valid record rejected: %v", err)
	}
	p.Kind = "photo"
	if _, err := validator.Validate(&p); err == nil {
		t.Error("unknown kind accepted")
	}

	for key, ok := range map[string]bool{"short": false, strings.Repeat("k", 8): true, strings.Repeat("k", 129): false} {
		if _, err := validator.Validate(&KeyPayload{KeyID: key}); (err == nil) != ok {
			t.Errorf("key_id of %d chars: valid = %v", len(key), err == nil)
		}
	}

	exchange := ExchangePayload{ID: "00000000-0000-4000-8000-000000000001", MacPublic: "bWFj"}
	if _, err := validator.Validate(&exchange); err != nil {
		t.Errorf("valid exchange rejected: %v", err)
	}
	exchange.SealedForPhone = strings.Repeat("A", 1028)
	if _, err := validator.Validate(&exchange); err == nil {
		t.Error("field over 1024 chars accepted")
	}
}
