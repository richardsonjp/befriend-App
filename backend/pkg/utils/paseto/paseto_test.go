package paseto

import (
	"testing"

	"befriend/config"
)

func setTestSecrets() {
	config.Config.PASETO.AccessSecret = "access-secret-for-tests"
	config.Config.PASETO.RefreshSecret = "refresh-secret-for-tests"
	config.Config.PASETO.AccessExpiryMin = 15
	config.Config.PASETO.RefreshExpiryDay = 7
}

func TestValidateToken(t *testing.T) {
	setTestSecrets()
	access, refresh, err := GenerateTokens(Claims{UserID: "user-1", DeviceID: "device-1"})
	if err != nil {
		t.Fatalf("GenerateTokens: %v", err)
	}
	noDevice, _, err := GenerateTokens(Claims{UserID: "user-1"})
	if err != nil {
		t.Fatalf("GenerateTokens without device: %v", err)
	}

	tests := []struct {
		name    string
		token   string
		secret  string
		wantErr bool
	}{
		{"access token with access secret", access, config.Config.PASETO.AccessSecret, false},
		{"refresh token with refresh secret", refresh, config.Config.PASETO.RefreshSecret, false},
		{"access token rejected as refresh", access, config.Config.PASETO.RefreshSecret, true},
		{"refresh token rejected as access", refresh, config.Config.PASETO.AccessSecret, true},
		{"token without device_id rejected", noDevice, config.Config.PASETO.AccessSecret, true},
		{"garbage rejected", "v4.local.not-a-token", config.Config.PASETO.AccessSecret, true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			claims, err := ValidateToken(tt.token, tt.secret)
			if tt.wantErr {
				if err == nil {
					t.Fatalf("expected an error, got claims %+v", claims)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if claims.UserID != "user-1" || claims.DeviceID != "device-1" {
				t.Fatalf("claims = %+v", claims)
			}
		})
	}
}

func TestHashToken(t *testing.T) {
	a := HashToken("token-a")
	if len(a) != 64 {
		t.Fatalf("want 64 hex chars, got %d", len(a))
	}
	if a != HashToken("token-a") {
		t.Fatal("hash is not deterministic")
	}
	if a == HashToken("token-b") {
		t.Fatal("different tokens hashed the same")
	}
}
