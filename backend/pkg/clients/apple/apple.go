// Package apple talks to Sign in with Apple's server endpoints.
package apple

import (
	"context"
	"crypto/ecdsa"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

const (
	tokenURL       = "https://appleid.apple.com/auth/token"
	secretAudience = "https://appleid.apple.com"
	requestTimeout = 10 * time.Second
)

type Config struct {
	TeamID        string
	KeyID         string
	PrivateKeyPEM string // contents of the .p8 key; literal "\n" sequences are accepted
}

type Client struct {
	cfg  Config
	key  *ecdsa.PrivateKey
	http *http.Client
}

// New returns a nil client (and no error) when server credentials aren't configured, so sign-in still
// works; only exchanging codes for Apple refresh tokens is skipped.
func New(cfg Config) (*Client, error) {
	if cfg.TeamID == "" || cfg.KeyID == "" || cfg.PrivateKeyPEM == "" {
		return nil, nil
	}
	key, err := jwt.ParseECPrivateKeyFromPEM([]byte(strings.ReplaceAll(cfg.PrivateKeyPEM, `\n`, "\n")))
	if err != nil {
		return nil, fmt.Errorf("apple: invalid private key: %w", err)
	}
	return &Client{cfg: cfg, key: key, http: &http.Client{Timeout: requestTimeout}}, nil
}

// ExchangeCode trades a Sign in with Apple authorization code for Apple's refresh token. clientID is the
// bundle ID the app signed in with (the identity token's audience).
func (c *Client) ExchangeCode(ctx context.Context, code, clientID string) (string, error) {
	secret, err := c.clientSecret(clientID)
	if err != nil {
		return "", err
	}

	form := url.Values{
		"client_id":     {clientID},
		"client_secret": {secret},
		"code":          {code},
		"grant_type":    {"authorization_code"},
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, tokenURL, strings.NewReader(form.Encode()))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")

	resp, err := c.http.Do(req)
	if err != nil {
		return "", fmt.Errorf("apple: token exchange: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	if err != nil {
		return "", fmt.Errorf("apple: token exchange: %w", err)
	}
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("apple: token exchange: HTTP %d: %s", resp.StatusCode, body)
	}

	var out struct {
		RefreshToken string `json:"refresh_token"`
	}
	if err := json.Unmarshal(body, &out); err != nil || out.RefreshToken == "" {
		return "", fmt.Errorf("apple: token exchange: no refresh token in response")
	}
	return out.RefreshToken, nil
}

// clientSecret is the short-lived ES256 JWT Apple requires instead of a static secret.
func (c *Client) clientSecret(clientID string) (string, error) {
	now := time.Now()
	token := jwt.NewWithClaims(jwt.SigningMethodES256, jwt.RegisteredClaims{
		Issuer:    c.cfg.TeamID,
		Subject:   clientID,
		Audience:  jwt.ClaimStrings{secretAudience},
		IssuedAt:  jwt.NewNumericDate(now),
		ExpiresAt: jwt.NewNumericDate(now.Add(5 * time.Minute)),
	})
	token.Header["kid"] = c.cfg.KeyID
	return token.SignedString(c.key)
}
