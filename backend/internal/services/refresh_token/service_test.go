package refresh_token

import (
	"testing"
	"time"

	"befriend/internal/model"
)

func TestDecide(t *testing.T) {
	now := time.Now()
	grace := time.Minute
	at := func(d time.Duration) *time.Time { t := now.Add(d); return &t }
	valid := now.Add(time.Hour)

	tests := []struct {
		name  string
		token model.RefreshToken
		want  Decision
	}{
		{"fresh token rotates", model.RefreshToken{ExpiresAt: valid}, DecisionRotate},
		{"rotated within grace rotates again", model.RefreshToken{ExpiresAt: valid, RotatedAt: at(-30 * time.Second)}, DecisionRotate},
		{"rotated exactly at grace edge rotates again", model.RefreshToken{ExpiresAt: valid, RotatedAt: at(-grace)}, DecisionRotate},
		{"rotated after grace is reuse", model.RefreshToken{ExpiresAt: valid, RotatedAt: at(-2 * time.Minute)}, DecisionReuseDetected},
		{"revoked is rejected", model.RefreshToken{ExpiresAt: valid, RevokedAt: at(-time.Minute)}, DecisionReject},
		{"revoked wins over reuse", model.RefreshToken{ExpiresAt: valid, RevokedAt: at(-time.Minute), RotatedAt: at(-time.Hour)}, DecisionReject},
		{"expired is rejected", model.RefreshToken{ExpiresAt: now}, DecisionReject},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := Decide(&tt.token, now, grace); got != tt.want {
				t.Fatalf("Decide = %v; want %v", got, tt.want)
			}
		})
	}
}
