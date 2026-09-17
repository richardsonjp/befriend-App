package openrouter

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"
)

func testRequest() Request {
	return Request{
		System: "system prompt", User: "user prompt", SchemaName: "friend_personality",
		Schema:    map[string]interface{}{"type": "object"},
		MaxTokens: 1000, Temperature: 0.9,
	}
}

func TestCompleteSendsStructuredRequest(t *testing.T) {
	var got map[string]interface{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/chat/completions" || r.Header.Get("Authorization") != "Bearer test-key" || r.Header.Get("X-Title") != "befriend" {
			t.Errorf("unexpected request: %s auth=%q title=%q", r.URL.Path, r.Header.Get("Authorization"), r.Header.Get("X-Title"))
		}
		_ = json.NewDecoder(r.Body).Decode(&got)
		_, _ = w.Write([]byte(`{"model":"nvidia/fallback:free","choices":[{"finish_reason":"stop","message":{"content":"{\"ok\":true}"}}]}`))
	}))
	defer srv.Close()

	c := New(Config{BaseURL: srv.URL + "/", APIKey: "test-key", Models: []string{"primary:free", "fallback:free"}, AppName: "befriend"})
	resp, err := c.Complete(t.Context(), testRequest())
	if err != nil {
		t.Fatalf("Complete: %v", err)
	}
	if resp.Content != `{"ok":true}` || resp.Model != "nvidia/fallback:free" {
		t.Fatalf("response = %+v", resp)
	}

	models, _ := got["models"].([]interface{})
	format, _ := got["response_format"].(map[string]interface{})
	schema, _ := format["json_schema"].(map[string]interface{})
	plugins, _ := got["plugins"].([]interface{})
	reasoning, _ := got["reasoning"].(map[string]interface{})
	switch {
	case len(models) != 2 || models[0] != "primary:free":
		t.Errorf("models = %v", got["models"])
	case format["type"] != "json_schema" || schema["name"] != "friend_personality" || schema["strict"] != true:
		t.Errorf("response_format = %v", got["response_format"])
	case len(plugins) != 1 || plugins[0].(map[string]interface{})["id"] != "response-healing":
		t.Errorf("plugins = %v", got["plugins"])
	// Without this a reasoning model thinks in prose until max_tokens and never emits the schema.
	case reasoning == nil || reasoning["enabled"] != false:
		t.Errorf("reasoning = %v", got["reasoning"])
	case got["max_tokens"] != float64(1000):
		t.Errorf("max_tokens = %v", got["max_tokens"])
	}
}

func TestCompleteErrors(t *testing.T) {
	now := time.Now()
	tests := []struct {
		name          string
		status        int
		headers       map[string]string
		body          string
		wantErr       string
		wantRateLimit time.Duration // >0: expect *RateLimitError with about this RetryAfter
	}{
		{name: "429 with Retry-After", status: 429, headers: map[string]string{"Retry-After": "30"},
			body: `{"error":{"code":429,"message":"Rate limit exceeded"}}`, wantRateLimit: 30 * time.Second},
		{name: "429 with reset in epoch milliseconds", status: 429,
			headers: map[string]string{"X-RateLimit-Reset": strconv.FormatInt(now.Add(90*time.Second).UnixMilli(), 10)},
			body:    `{"error":{"code":429,"message":"Rate limit exceeded"}}`, wantRateLimit: 90 * time.Second},
		{name: "429 with reset in epoch seconds", status: 429,
			headers: map[string]string{"X-RateLimit-Reset": strconv.FormatInt(now.Add(120*time.Second).Unix(), 10)},
			body:    `{}`, wantRateLimit: 120 * time.Second},
		{name: "429 without hints defaults to a minute", status: 429, body: `{}`, wantRateLimit: time.Minute},
		{name: "server error carries the message", status: 502, body: `{"error":{"code":502,"message":"provider down"}}`, wantErr: "HTTP 502: provider down"},
		{name: "error object in a 200", status: 200, body: `{"error":{"message":"no endpoints found"}}`, wantErr: "no endpoints found"},
		{name: "no choices", status: 200, body: `{"choices":[]}`, wantErr: "empty response"},
		{name: "truncated by max_tokens", status: 200,
			body: `{"choices":[{"finish_reason":"length","message":{"content":"{\"summary\":"}}]}`, wantErr: "truncated"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				for k, v := range tt.headers {
					w.Header().Set(k, v)
				}
				w.WriteHeader(tt.status)
				_, _ = w.Write([]byte(tt.body))
			}))
			defer srv.Close()

			_, err := New(Config{BaseURL: srv.URL, APIKey: "secret-key", Models: []string{"m:free"}}).Complete(t.Context(), testRequest())
			if err == nil {
				t.Fatal("expected an error")
			}
			if strings.Contains(err.Error(), "secret-key") {
				t.Fatalf("error leaks the API key: %v", err)
			}
			if tt.wantRateLimit > 0 {
				rl, ok := err.(*RateLimitError)
				if !ok {
					t.Fatalf("error = %T %v; want *RateLimitError", err, err)
				}
				if diff := rl.RetryAfter - tt.wantRateLimit; diff < -5*time.Second || diff > 5*time.Second {
					t.Fatalf("RetryAfter = %s; want about %s", rl.RetryAfter, tt.wantRateLimit)
				}
				return
			}
			if !strings.Contains(err.Error(), tt.wantErr) {
				t.Fatalf("error = %v; want one containing %q", err, tt.wantErr)
			}
		})
	}
}

func TestNewWithoutKeyIsDisabled(t *testing.T) {
	if New(Config{Models: []string{"m:free"}}) != nil || New(Config{APIKey: "k"}) != nil {
		t.Fatal("New should return nil without an API key or models")
	}
}
