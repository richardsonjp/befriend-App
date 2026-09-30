package chat_sync

import (
	"context"
	"os"
	"testing"
	"time"

	"befriend/config"
	"befriend/internal/model"
	repoChatSync "befriend/internal/repositories/chat_sync"
	"befriend/internal/repositories/tx"
	"befriend/pkg/clients/db"
	"befriend/pkg/utils/errors"
)

// TestChatSyncOnPostgres runs the service against a real Postgres: last-writer-wins and seq live in SQL.
// It only runs with CHAT_SYNC_TEST_DB naming a migrated database on the local docker compose Postgres
// (localhost, compose credentials; never .env). For example:
//
//	docker exec backend-postgres-1 createdb -U befriend befriend_chatsync_test
//	for f in cmd/apiserver/app/migrations/*.up.sql; do docker exec -i backend-postgres-1 psql -q -U befriend -d befriend_chatsync_test < $f; done
//	CHAT_SYNC_TEST_DB=befriend_chatsync_test go test ./internal/services/chat_sync/
func TestChatSyncOnPostgres(t *testing.T) {
	name := os.Getenv("CHAT_SYNC_TEST_DB")
	if name == "" {
		t.Skip("set CHAT_SYNC_TEST_DB to run against the local Postgres")
	}
	config.Config.DB.Host = "localhost" // hard-wired: this test must never reach a remote database
	config.Config.DB.Port = "5432"
	config.Config.DB.Username = "befriend"
	config.Config.DB.Password = "befriend"
	config.Config.DB.Name = name
	config.Config.DB.TimeZone = "UTC"
	dbdget := db.NewDBdelegate(false)
	dbdget.Init()
	defer dbdget.Close()

	ctx := context.Background()
	gdb := dbdget.Get(ctx)
	newUser := func() string {
		var id string
		if err := gdb.Raw(`INSERT INTO "user" DEFAULT VALUES RETURNING id`).Scan(&id).Error; err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { gdb.Exec(`DELETE FROM "user" WHERE id = ?`, id) })
		return id
	}
	s := NewChatSyncService(tx.NewTxRepo(dbdget), repoChatSync.NewChatSyncRepo(dbdget))
	alice, bob := newUser(), newUser()

	t.Run("key", func(t *testing.T) {
		if got, err := s.GetKey(ctx, alice); err != nil || got.KeyID != nil {
			t.Fatalf("no key yet: %+v, %v", got, err)
		}
		if _, err := s.SetKey(ctx, KeyPayload{UserID: alice, KeyID: "key-one-1"}); err != nil {
			t.Fatal(err)
		}
		if _, err := s.SetKey(ctx, KeyPayload{UserID: alice, KeyID: "key-one-1"}); err != nil {
			t.Errorf("same key again: %v", err)
		}
		if _, err := s.SetKey(ctx, KeyPayload{UserID: alice, KeyID: "key-two-2"}); !errors.Is(err, "CHAT_KEY_MISMATCH") {
			t.Errorf("different key: %v", err)
		}
		if got, _ := s.GetKey(ctx, alice); got.KeyID == nil || *got.KeyID != "key-one-1" {
			t.Errorf("stored key = %+v", got)
		}
	})

	t.Run("records", func(t *testing.T) {
		base := time.Date(2026, 10, 1, 9, 0, 0, 123456789, time.UTC)
		put := func(user, id string, at time.Time, deleted bool, blob string) *PutRecordResponse {
			t.Helper()
			res, err := s.PutRecord(ctx, RecordPayload{UserID: user, Kind: "conversation", ID: id, ModifiedAt: at, Deleted: deleted, Blob: []byte(blob)})
			if err != nil {
				t.Fatal(err)
			}
			return res
		}
		a := "00000000-0000-4000-8000-00000000000a"
		b := "00000000-0000-4000-8000-00000000000b"

		first := put(alice, a, base, false, "v1")
		if !first.Applied {
			t.Fatal("insert not applied")
		}
		second := put(alice, a, base.Add(time.Second), false, "v2")
		if !second.Applied || second.Seq <= first.Seq {
			t.Errorf("newer write: %+v after %+v; want applied with a higher seq", second, first)
		}
		stale := put(alice, a, base, false, "old")
		if stale.Applied || stale.Seq != second.Seq {
			t.Errorf("stale write: %+v; want not applied, seq %d", stale, second.Seq)
		}
		resend := put(alice, a, base.Add(time.Second), false, "v2")
		if !resend.Applied || resend.Seq <= second.Seq {
			t.Errorf("same modified_at: %+v; want applied (>=) with a new seq", resend)
		}
		put(bob, a, base, false, "bob's") // same record id, other user: separate row
		put(alice, b, base, false, "b1")
		tomb := put(alice, b, base.Add(time.Minute), true, "")
		if !tomb.Applied {
			t.Error("tombstone not applied")
		}
		var size int
		var blobNull bool
		gdb.Raw(`SELECT size, blob IS NULL FROM chat_records WHERE user_id = ? AND record_id = ?`, alice, b).Row().Scan(&size, &blobNull)
		if size != 0 || !blobNull {
			t.Errorf("tombstone row: size %d, blob null %v", size, blobNull)
		}

		page, err := s.ListRecords(ctx, ListRecordsPayload{UserID: alice, After: 0, Limit: 1})
		if err != nil {
			t.Fatal(err)
		}
		if len(page.Records) != 1 || !page.More || page.Records[0].ID != a || string(page.Records[0].Blob) != "v2" {
			t.Fatalf("first page = %+v", page)
		}
		if page.Records[0].ModifiedAt != "2026-10-01T09:00:01.123456Z" {
			t.Errorf("modified_at = %q", page.Records[0].ModifiedAt)
		}
		page, _ = s.ListRecords(ctx, ListRecordsPayload{UserID: alice, After: page.Next})
		if len(page.Records) != 1 || page.More || page.Records[0].ID != b || !page.Records[0].Deleted || page.Records[0].Blob != nil {
			t.Fatalf("second page = %+v; want b's tombstone only", page)
		}
		end, _ := s.ListRecords(ctx, ListRecordsPayload{UserID: alice, After: page.Next})
		if len(end.Records) != 0 || end.More || end.Next != page.Next {
			t.Errorf("past the end = %+v", end)
		}
		bobs, _ := s.ListRecords(ctx, ListRecordsPayload{UserID: bob})
		if len(bobs.Records) != 1 || string(bobs.Records[0].Blob) != "bob's" {
			t.Errorf("bob sees %+v", bobs)
		}
	})

	t.Run("exchanges", func(t *testing.T) {
		id := "00000000-0000-4000-8000-0000000000e1"
		if _, err := s.GetExchange(ctx, alice, id); !errors.Is(err, "CHAT_EXCHANGE_NOT_FOUND") {
			t.Errorf("missing: %v", err)
		}
		if _, err := s.PutExchange(ctx, ExchangePayload{UserID: alice, ID: id, MacPublic: "bWFj"}); err != nil {
			t.Fatal(err)
		}
		got, err := s.PutExchange(ctx, ExchangePayload{UserID: alice, ID: id, PhonePublic: "cGhvbmU=", MacPublic: "bWFj"})
		if err != nil || got.MacPublic == nil || *got.PhonePublic != "cGhvbmU=" || got.SealedForMac != nil {
			t.Fatalf("merge = %+v, %v", got, err)
		}
		if _, err := s.PutExchange(ctx, ExchangePayload{UserID: alice, ID: id, MacPublic: "b3RoZXI="}); !errors.Is(err, "CHAT_EXCHANGE_CONFLICT") {
			t.Errorf("overwrite: %v", err)
		}
		if got, err := s.GetExchange(ctx, alice, id); err != nil || *got.MacPublic != "bWFj" {
			t.Errorf("get = %+v, %v", got, err)
		}
		if _, err := s.GetExchange(ctx, bob, id); !errors.Is(err, "CHAT_EXCHANGE_NOT_FOUND") {
			t.Errorf("bob get: %v", err)
		}
		if _, err := s.PutExchange(ctx, ExchangePayload{UserID: bob, ID: id, SealedForMac: "eA=="}); !errors.Is(err, "CHAT_EXCHANGE_NOT_FOUND") {
			t.Errorf("bob put: %v", err)
		}

		gdb.Exec(`UPDATE chat_key_exchanges SET expires_at = NOW() - INTERVAL '1 second' WHERE id = ?`, id)
		if _, err := s.GetExchange(ctx, alice, id); !errors.Is(err, "CHAT_EXCHANGE_NOT_FOUND") {
			t.Errorf("expired get: %v", err)
		}
		fresh, err := s.PutExchange(ctx, ExchangePayload{UserID: bob, ID: id, MacPublic: "bmV3"})
		if err != nil || *fresh.MacPublic != "bmV3" || fresh.PhonePublic != nil {
			t.Errorf("expired exchange should start over: %+v, %v", fresh, err)
		}
	})

	t.Run("account deletion cascades", func(t *testing.T) {
		gdb.Exec(`DELETE FROM "user" WHERE id = ?`, alice)
		var n int64
		for _, table := range []string{"chat_sync_keys", "chat_records", "chat_key_exchanges"} {
			gdb.Table(table).Where("user_id = ?", alice).Count(&n)
			if n != 0 {
				t.Errorf("%s keeps %d rows of a deleted user", table, n)
			}
		}
		gdb.Model(&model.ChatRecord{}).Where("user_id = ?", bob).Count(&n)
		if n != 1 {
			t.Errorf("bob's records: %d", n)
		}
	})
}
