package verification_code

import (
	"testing"
	"time"

	"befriend/internal/model"
)

func TestEvaluateCode(t *testing.T) {
	now := time.Now()
	code := func(attempts int, expiresAt time.Time) *model.VerificationCode {
		return &model.VerificationCode{Code: "123456", Attempts: attempts, ExpiresAt: expiresAt}
	}
	valid := now.Add(time.Minute)

	tests := []struct {
		name         string
		data         *model.VerificationCode
		submitted    string
		wantAccepted bool
		wantCount    bool
	}{
		{"correct code accepted", code(0, valid), "123456", true, false},
		{"wrong code counts an attempt", code(0, valid), "654321", false, true},
		{"shorter code never matches", code(0, valid), "12345", false, true},
		{"last allowed attempt still accepted", code(maxAttempts-1, valid), "123456", true, false},
		{"locked after max attempts, even with the right code", code(maxAttempts, valid), "123456", false, false},
		{"expired code refused without counting", code(0, now.Add(-time.Second)), "123456", false, false},
		{"code expiring exactly now is expired", code(0, now), "123456", false, false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			accepted, count := evaluateCode(tt.data, tt.submitted, now)
			if accepted != tt.wantAccepted || count != tt.wantCount {
				t.Fatalf("evaluateCode = (accepted %v, count %v); want (%v, %v)", accepted, count, tt.wantAccepted, tt.wantCount)
			}
		})
	}
}
