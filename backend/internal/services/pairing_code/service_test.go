package pairing_code

import (
	"strings"
	"testing"
	"time"

	"befriend/internal/model"
)

func TestRandomCode(t *testing.T) {
	seen := map[string]bool{}
	for i := 0; i < 200; i++ {
		code, err := randomCode()
		if err != nil {
			t.Fatal(err)
		}
		if len(code) != codeLength || strings.Trim(code, codeAlphabet) != "" {
			t.Fatalf("code %q: want %d symbols from the alphabet", code, codeLength)
		}
		seen[code] = true
	}
	if len(seen) < 199 {
		t.Errorf("only %d distinct codes in 200", len(seen))
	}
}

func TestNormalizeCode(t *testing.T) {
	for in, want := range map[string]string{"abcd-efgh": "ABCDEFGH", " AB CD EF GH ": "ABCDEFGH", "ABCDEFGH": "ABCDEFGH"} {
		if got := normalizeCode(in); got != want {
			t.Errorf("normalizeCode(%q) = %q; want %q", in, got, want)
		}
	}
}

func TestClaimStateOf(t *testing.T) {
	now := time.Date(2026, 9, 11, 10, 0, 0, 0, time.UTC)
	secret := strings.Repeat("ab", 32)
	user := "user-1"
	earlier := now.Add(-time.Minute)
	pairing := func(expiresIn time.Duration, confirmed, consumed bool) *model.PairingCode {
		m := &model.PairingCode{PollSecretHash: hash(secret), ExpiresAt: now.Add(expiresIn)}
		if confirmed {
			m.ConfirmedAt, m.UserID = &earlier, &user
		}
		if consumed {
			m.ConsumedAt = &earlier
		}
		return m
	}

	tests := []struct {
		name   string
		m      *model.PairingCode
		secret string
		want   claimState
	}{
		{"waiting for the iPhone", pairing(time.Minute, false, false), secret, claimPending},
		{"secret is case-insensitive hex", pairing(time.Minute, false, false), strings.ToUpper(secret), claimPending},
		{"confirmed", pairing(time.Minute, true, false), secret, claimReady},
		{"confirmed, just expired", pairing(-10*time.Second, true, false), secret, claimReady},
		{"confirmed, long expired", pairing(-time.Minute, true, false), secret, claimGone},
		{"expired unconfirmed", pairing(-time.Second, false, false), secret, claimGone},
		{"already claimed", pairing(time.Minute, true, true), secret, claimGone},
		{"wrong secret", pairing(time.Minute, true, false), strings.Repeat("cd", 32), claimGone},
	}
	for _, tt := range tests {
		if got := claimStateOf(tt.m, tt.secret, now); got != tt.want {
			t.Errorf("%s: got %d; want %d", tt.name, got, tt.want)
		}
	}
}

func TestCleanName(t *testing.T) {
	if got := cleanName("  Rich's\u200b\nMacBook\tPro  "); got != "Rich's MacBook Pro" {
		t.Errorf("cleanName = %q", got)
	}
}
