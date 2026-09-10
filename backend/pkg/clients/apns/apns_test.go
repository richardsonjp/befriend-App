package apns

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/golang-jwt/jwt/v5"
)

func testClient(t *testing.T, handler http.HandlerFunc) (*Client, *ecdsa.PublicKey) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, _ := x509.MarshalPKCS8PrivateKey(key)
	pemKey := strings.ReplaceAll(string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})), "\n", `\n`)
	c, err := New(Config{TeamID: "TEAM", KeyID: "KEY", PrivateKeyPEM: pemKey, BundleID: "com.example.app"})
	if err != nil {
		t.Fatal(err)
	}

	server := httptest.NewUnstartedServer(handler)
	server.EnableHTTP2 = true
	server.StartTLS()
	t.Cleanup(server.Close)
	c.http = server.Client()
	c.productionURL, c.sandboxURL = server.URL+"/prod", server.URL+"/sandbox"
	return c, &key.PublicKey
}

func TestSendLiveActivityOverHTTP2(t *testing.T) {
	var mu sync.Mutex
	var tokens []string
	c, pub := testClient(t, func(w http.ResponseWriter, r *http.Request) {
		if r.ProtoMajor != 2 {
			t.Errorf("proto = %s; want HTTP/2", r.Proto)
		}
		if r.URL.Path != "/sandbox/3/device/abc123" {
			t.Errorf("path = %s", r.URL.Path)
		}
		for header, want := range map[string]string{"apns-push-type": "liveactivity", "apns-topic": "com.example.app.push-type.liveactivity", "apns-priority": "5"} {
			if got := r.Header.Get(header); got != want {
				t.Errorf("%s = %q; want %q", header, got, want)
			}
		}
		body, _ := io.ReadAll(r.Body)
		if !strings.Contains(string(body), `"event":"update"`) {
			t.Errorf("body = %s", body)
		}
		mu.Lock()
		tokens = append(tokens, strings.TrimPrefix(r.Header.Get("authorization"), "bearer "))
		mu.Unlock()
	})

	n := Notification{DeviceToken: "abc123", Sandbox: true, PushType: PushTypeLiveActivity, Priority: 5,
		Payload: map[string]interface{}{"aps": map[string]interface{}{"event": "update"}}}
	for i := 0; i < 2; i++ {
		if err := c.Send(context.Background(), n); err != nil {
			t.Fatalf("send %d: %v", i, err)
		}
	}

	if len(tokens) != 2 || tokens[0] != tokens[1] {
		t.Fatalf("provider token not reused: %v", tokens)
	}
	parsed, err := jwt.Parse(tokens[0], func(*jwt.Token) (interface{}, error) { return pub, nil }, jwt.WithValidMethods([]string{"ES256"}))
	if err != nil {
		t.Fatalf("provider token invalid: %v", err)
	}
	if parsed.Header["kid"] != "KEY" || parsed.Claims.(jwt.MapClaims)["iss"] != "TEAM" {
		t.Errorf("provider token header/claims: %v %v", parsed.Header, parsed.Claims)
	}
}

func TestSendErrors(t *testing.T) {
	calls := 0
	c, _ := testClient(t, func(w http.ResponseWriter, r *http.Request) {
		calls++
		switch r.URL.Path {
		case "/prod/3/device/gone":
			w.WriteHeader(http.StatusGone)
			json.NewEncoder(w).Encode(map[string]string{"reason": "Unregistered"})
		case "/prod/3/device/expired":
			if calls == 1 {
				w.WriteHeader(http.StatusForbidden)
				json.NewEncoder(w).Encode(map[string]string{"reason": "ExpiredProviderToken"})
			}
		default:
			w.WriteHeader(http.StatusBadRequest)
			json.NewEncoder(w).Encode(map[string]string{"reason": "BadPriority"})
		}
	})

	send := func(token string) error {
		return c.Send(context.Background(), Notification{DeviceToken: token, PushType: PushTypeWidgets, Priority: 5, Payload: map[string]interface{}{}})
	}
	if err := send("expired"); err != nil || calls != 2 {
		t.Errorf("expired provider token: err = %v after %d calls; want a successful retry", err, calls)
	}
	if err := send("gone"); !errors.Is(err, ErrUnregistered) {
		t.Errorf("gone: err = %v; want ErrUnregistered", err)
	}
	if err := send("other"); err == nil || !strings.Contains(err.Error(), "BadPriority") {
		t.Errorf("other: err = %v", err)
	}
}

func TestNewWithoutCredentials(t *testing.T) {
	if c, err := New(Config{TeamID: "TEAM"}); c != nil || err != nil {
		t.Errorf("New() = %v, %v; want nil, nil", c, err)
	}
}
