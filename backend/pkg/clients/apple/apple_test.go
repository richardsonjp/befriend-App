package apple

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/pem"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/golang-jwt/jwt/v5"
)

// testClient returns a client whose requests go to handler, plus the public key its client secrets verify with.
func testClient(t *testing.T, handler http.HandlerFunc) (*Client, *ecdsa.PublicKey) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	pemKey := strings.ReplaceAll(string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})), "\n", `\n`)

	c, err := New(Config{TeamID: "TEAM123", KeyID: "KEY456", PrivateKeyPEM: pemKey})
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	c.baseURL = server.URL
	return c, &key.PublicKey
}

func TestNewWithoutCredentials(t *testing.T) {
	c, err := New(Config{TeamID: "TEAM123"})
	if c != nil || err != nil {
		t.Fatalf("New() = %v, %v; want nil, nil", c, err)
	}
}

func TestRevokeRefreshToken(t *testing.T) {
	var got http.Request
	c, pub := testClient(t, func(w http.ResponseWriter, r *http.Request) {
		if err := r.ParseForm(); err != nil {
			t.Error(err)
		}
		got = *r
	})

	if err := c.RevokeRefreshToken(context.Background(), "apple-refresh", "com.example.app"); err != nil {
		t.Fatalf("RevokeRefreshToken() error = %v", err)
	}
	if got.URL.Path != "/auth/revoke" {
		t.Errorf("path = %q; want /auth/revoke", got.URL.Path)
	}
	for field, want := range map[string]string{"token": "apple-refresh", "token_type_hint": "refresh_token", "client_id": "com.example.app"} {
		if v := got.PostForm.Get(field); v != want {
			t.Errorf("%s = %q; want %q", field, v, want)
		}
	}

	claims := &jwt.RegisteredClaims{}
	secret, err := jwt.ParseWithClaims(got.PostForm.Get("client_secret"), claims, func(*jwt.Token) (interface{}, error) { return pub, nil },
		jwt.WithValidMethods([]string{"ES256"}), jwt.WithAudience(secretAudience), jwt.WithIssuer("TEAM123"))
	if err != nil {
		t.Fatalf("client_secret invalid: %v", err)
	}
	if claims.Subject != "com.example.app" || secret.Header["kid"] != "KEY456" {
		t.Errorf("client_secret sub = %q, kid = %v", claims.Subject, secret.Header["kid"])
	}
}

func TestPostErrors(t *testing.T) {
	c, _ := testClient(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/auth/token" {
			w.Write([]byte(`{"access_token":"a"}`))
			return
		}
		w.WriteHeader(http.StatusBadRequest)
		w.Write([]byte(`{"error":"invalid_client"}`))
	})

	if err := c.RevokeRefreshToken(context.Background(), "t", "com.example.app"); err == nil || !strings.Contains(err.Error(), "HTTP 400") {
		t.Errorf("revoke error = %v; want HTTP 400", err)
	}
	if _, err := c.ExchangeCode(context.Background(), "code", "com.example.app"); err == nil || !strings.Contains(err.Error(), "no refresh token") {
		t.Errorf("exchange error = %v; want missing refresh token", err)
	}
}
