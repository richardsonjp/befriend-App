package idtoken

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"math/big"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

const (
	testKID      = "test-key"
	testIssuer   = "https://issuer.example"
	testAudience = "com.example.app"
	rawNonce     = "0123456789abcdef-raw-nonce"
)

// jwksServer serves a JWK Set containing the public half of key.
func jwksServer(t *testing.T, key *rsa.PrivateKey) *httptest.Server {
	t.Helper()
	b64 := base64.RawURLEncoding.EncodeToString
	set := map[string]interface{}{"keys": []map[string]string{{
		"kty": "RSA", "kid": testKID, "use": "sig", "alg": "RS256",
		"n": b64(key.N.Bytes()), "e": b64(big.NewInt(int64(key.E)).Bytes()),
	}}}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(set)
	}))
	t.Cleanup(srv.Close)
	return srv
}

func sign(t *testing.T, method jwt.SigningMethod, key interface{}, kid string, c jwt.MapClaims) string {
	t.Helper()
	token := jwt.NewWithClaims(method, c)
	token.Header["kid"] = kid
	s, err := token.SignedString(key)
	if err != nil {
		t.Fatalf("sign: %v", err)
	}
	return s
}

func baseClaims(nonce string, emailVerified interface{}) jwt.MapClaims {
	now := time.Now()
	return jwt.MapClaims{
		"iss": testIssuer, "aud": testAudience, "sub": "provider-user-1",
		"iat": now.Unix(), "exp": now.Add(10 * time.Minute).Unix(),
		"email": "friend@example.com", "email_verified": emailVerified, "nonce": nonce,
	}
}

func hashed(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hex.EncodeToString(sum[:])
}

func TestVerify(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	otherKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	srv := jwksServer(t, key)

	newVerifier := func(hashNonce bool) *Verifier {
		v, err := New(t.Context(), Config{
			JWKSURL: srv.URL, Issuers: []string{testIssuer}, Audiences: []string{"other.app", testAudience}, HashNonce: hashNonce,
		})
		if err != nil || v == nil {
			t.Fatalf("New: %v", err)
		}
		return v
	}
	apple, google := newVerifier(true), newVerifier(false)

	with := func(c jwt.MapClaims, k string, val interface{}) jwt.MapClaims { c[k] = val; return c }
	publicPEM := pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: func() []byte {
		b, _ := x509.MarshalPKIXPublicKey(&key.PublicKey)
		return b
	}()})

	tests := []struct {
		name      string
		verifier  *Verifier
		token     string
		nonce     string
		wantErr   bool
		wantEmail bool
	}{
		{"apple token with hashed nonce and string email_verified", apple,
			sign(t, jwt.SigningMethodRS256, key, testKID, baseClaims(hashed(rawNonce), "true")), rawNonce, false, true},
		{"google token with raw nonce and boolean email_verified", google,
			sign(t, jwt.SigningMethodRS256, key, testKID, baseClaims(rawNonce, true)), rawNonce, false, true},
		{"unverified email is reported as unverified", google,
			sign(t, jwt.SigningMethodRS256, key, testKID, baseClaims(rawNonce, "false")), rawNonce, false, false},
		{"wrong audience", google,
			sign(t, jwt.SigningMethodRS256, key, testKID, with(baseClaims(rawNonce, true), "aud", "evil.app")), rawNonce, true, false},
		{"wrong issuer", google,
			sign(t, jwt.SigningMethodRS256, key, testKID, with(baseClaims(rawNonce, true), "iss", "https://evil.example")), rawNonce, true, false},
		{"expired", google,
			sign(t, jwt.SigningMethodRS256, key, testKID, with(baseClaims(rawNonce, true), "exp", time.Now().Add(-time.Hour).Unix())), rawNonce, true, false},
		{"missing expiry", google,
			sign(t, jwt.SigningMethodRS256, key, testKID, func() jwt.MapClaims { c := baseClaims(rawNonce, true); delete(c, "exp"); return c }()), rawNonce, true, false},
		{"raw nonce where apple expects its hash", apple,
			sign(t, jwt.SigningMethodRS256, key, testKID, baseClaims(rawNonce, true)), rawNonce, true, false},
		{"nonce from a different sign-in", google,
			sign(t, jwt.SigningMethodRS256, key, testKID, baseClaims(rawNonce, true)), "another-nonce-value-123", true, false},
		{"empty nonce never matches", google,
			sign(t, jwt.SigningMethodRS256, key, testKID, baseClaims("", true)), "", true, false},
		{"signed by an unknown key", google,
			sign(t, jwt.SigningMethodRS256, otherKey, testKID, baseClaims(rawNonce, true)), rawNonce, true, false},
		{"unknown key id", google,
			sign(t, jwt.SigningMethodRS256, key, "unknown-kid", baseClaims(rawNonce, true)), rawNonce, true, false},
		{"HS256 signed with the public key (algorithm confusion)", google,
			sign(t, jwt.SigningMethodHS256, publicPEM, testKID, baseClaims(rawNonce, true)), rawNonce, true, false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			identity, err := tt.verifier.Verify(t.Context(), tt.token, tt.nonce)
			if tt.wantErr {
				if err == nil {
					t.Fatalf("expected an error, got %+v", identity)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if identity.Subject != "provider-user-1" || identity.Email != "friend@example.com" ||
				identity.EmailVerified != tt.wantEmail || identity.Audience != testAudience {
				t.Fatalf("identity = %+v", identity)
			}
		})
	}
}

func TestNewWithoutAudiencesIsDisabled(t *testing.T) {
	v, err := New(t.Context(), Config{JWKSURL: "http://127.0.0.1:1/unused"})
	if v != nil || err != nil {
		t.Fatalf("New without audiences = (%v, %v); want (nil, nil)", v, err)
	}
}
