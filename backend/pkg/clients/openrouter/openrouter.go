// Package openrouter calls OpenRouter's chat completions API for structured (JSON schema) output.
package openrouter

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"
)

const (
	defaultBaseURL    = "https://openrouter.ai/api/v1"
	defaultTimeout    = 3 * time.Minute // a full personality + phrasebook is several thousand tokens
	defaultRetryAfter = time.Minute
	maxResponseBytes  = 16 << 20
)

type Config struct {
	BaseURL string   // defaults to OpenRouter; changed only for local tests
	APIKey  string   //nolint:gosec // read from env, never logged
	Models  []string // tried in order by OpenRouter (it falls back on errors and rate limits)
	AppName string   // sent as X-Title for attribution
	Timeout time.Duration
}

type Client struct {
	cfg  Config
	http *http.Client
}

// Request is one structured completion: a system and user message plus the JSON schema the reply must match.
type Request struct {
	System      string
	User        string
	SchemaName  string
	Schema      map[string]interface{}
	MaxTokens   int
	Temperature float64
}

type Response struct {
	Content string // the JSON document produced by the model
	Model   string // the model that actually answered
}

// RateLimitError is a 429. The client never retries on its own: the caller reschedules after RetryAfter.
type RateLimitError struct {
	RetryAfter time.Duration
	Message    string
}

func (e *RateLimitError) Error() string {
	return fmt.Sprintf("openrouter: rate limited (retry after %s): %s", e.RetryAfter, e.Message)
}

// New returns nil when no API key is configured, so generation stays queued instead of failing.
func New(cfg Config) *Client {
	if cfg.APIKey == "" || len(cfg.Models) == 0 {
		return nil
	}
	if cfg.BaseURL == "" {
		cfg.BaseURL = defaultBaseURL
	}
	if cfg.Timeout <= 0 {
		cfg.Timeout = defaultTimeout
	}
	return &Client{cfg: cfg, http: &http.Client{Timeout: cfg.Timeout}}
}

func (c *Client) Complete(ctx context.Context, req Request) (*Response, error) {
	body, err := json.Marshal(map[string]interface{}{
		"models": c.cfg.Models,
		"messages": []map[string]string{
			{"role": "system", "content": req.System},
			{"role": "user", "content": req.User},
		},
		"response_format": map[string]interface{}{
			"type": "json_schema",
			"json_schema": map[string]interface{}{
				"name":   req.SchemaName,
				"strict": true,
				"schema": req.Schema,
			},
		},
		// Repairs markdown fences, trailing commas and similar; our own validation still runs afterwards.
		"plugins":     []map[string]string{{"id": "response-healing"}},
		"max_tokens":  req.MaxTokens,
		"temperature": req.Temperature,
	})
	if err != nil {
		return nil, fmt.Errorf("openrouter: encode request: %w", err)
	}

	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(c.cfg.BaseURL, "/")+"/chat/completions", bytes.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("openrouter: build request: %w", err)
	}
	httpReq.Header.Set("Authorization", "Bearer "+c.cfg.APIKey)
	httpReq.Header.Set("Content-Type", "application/json")
	if c.cfg.AppName != "" {
		httpReq.Header.Set("X-Title", c.cfg.AppName)
	}

	resp, err := c.http.Do(httpReq)
	if err != nil {
		return nil, fmt.Errorf("openrouter: %w", err)
	}
	defer resp.Body.Close()

	data, err := io.ReadAll(io.LimitReader(resp.Body, maxResponseBytes))
	if err != nil {
		return nil, fmt.Errorf("openrouter: read response: %w", err)
	}
	if resp.StatusCode == http.StatusTooManyRequests {
		return nil, &RateLimitError{RetryAfter: retryAfter(resp.Header, time.Now()), Message: errorMessage(data)}
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("openrouter: HTTP %d: %s", resp.StatusCode, errorMessage(data))
	}

	var out struct {
		Model   string `json:"model"`
		Choices []struct {
			FinishReason string `json:"finish_reason"`
			Message      struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
		Error *struct {
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal(data, &out); err != nil {
		return nil, fmt.Errorf("openrouter: decode response: %w", err)
	}
	switch {
	case out.Error != nil:
		return nil, fmt.Errorf("openrouter: %s", out.Error.Message)
	case len(out.Choices) == 0 || strings.TrimSpace(out.Choices[0].Message.Content) == "":
		return nil, fmt.Errorf("openrouter: empty response")
	case out.Choices[0].FinishReason == "length":
		return nil, fmt.Errorf("openrouter: response truncated by max_tokens")
	}
	return &Response{Content: out.Choices[0].Message.Content, Model: out.Model}, nil
}

// retryAfter prefers Retry-After (seconds), then X-RateLimit-Reset (epoch seconds or milliseconds),
// then a one-minute default.
func retryAfter(h http.Header, now time.Time) time.Duration {
	if s, err := strconv.Atoi(h.Get("Retry-After")); err == nil && s > 0 {
		return time.Duration(s) * time.Second
	}
	if v, err := strconv.ParseInt(h.Get("X-RateLimit-Reset"), 10, 64); err == nil && v > 0 {
		reset := time.UnixMilli(v)
		if v < 1e12 {
			reset = time.Unix(v, 0)
		}
		if d := reset.Sub(now); d > 0 {
			return d
		}
	}
	return defaultRetryAfter
}

func errorMessage(body []byte) string {
	var e struct {
		Error struct {
			Message string `json:"message"`
		} `json:"error"`
	}
	if json.Unmarshal(body, &e) == nil && e.Error.Message != "" {
		return e.Error.Message
	}
	return "unexpected response"
}
