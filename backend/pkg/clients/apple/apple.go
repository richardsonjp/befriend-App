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
	defaultBaseURL = "https://appleid.apple.com"
	secretAudience = "https://appleid.apple.com"
	requestTimeout = 10 * time.Second
)

type Config struct {
	TeamID        string
	KeyID         string
	PrivateKeyPEM string // contents of the .p8 key; literal "\n" sequences are accepted
}

type Client struct {
	cfg     Config
	key     *ecdsa.PrivateKey
	http    *http.Client
	baseURL string // tests point this at a local server
}

// New returns a nil client (and no error) when server credentials aren't configured, so sign-in still
// works; only exchanging codes for Apple refresh tokens (and revoking them) is skipped.
func New(cfg Config) (*Client, error) {
	if cfg.TeamID == "" || cfg.KeyID == "" || cfg.PrivateKeyPEM == "" {
		return nil, nil
	}
	key, err := jwt.ParseECPrivateKeyFromPEM([]byte(strings.ReplaceAll(cfg.PrivateKeyPEM, `\n`, "\n")))
	if err != nil {
		return nil, fmt.Errorf("apple: invalid private key: %w", err)
	}
	return &Client{cfg: cfg, key: key, http: &http.Client{Timeout: requestTimeout}, baseURL: defaultBaseURL}, nil
}

// ExchangeCode trades a Sign in with Apple authorization code for Apple's refresh token. clientID is the
// bundle ID the app signed in with (the identity token's audience).
func (c *Client) ExchangeCode(ctx context.Context, code, clientID string) (string, error) {
	body, err := c.post(ctx, "/auth/token", clientID, url.Values{
		"code":       {code},
		"grant_type": {"authorization_code"},
	})
	if err != nil {
		return "", fmt.Errorf("apple: token exchange: %w", err)
	}

	var out struct {
		RefreshToken string `json:"refresh_token"`
	}
	if err := json.Unmarshal(body, &out); err != nil || out.RefreshToken == "" {
		return "", fmt.Errorf("apple: token exchange: no refresh token in response")
	}
	return out.RefreshToken, nil
}

// RevokeRefreshToken ends the app's Sign in with Apple authorization for that user, as App Review requires
// when an account is deleted.
func (c *Client) RevokeRefreshToken(ctx context.Context, refreshToken, clientID string) error {
	_, err := c.post(ctx, "/auth/revoke", clientID, url.Values{
		"token":           {refreshToken},
		"token_type_hint": {"refresh_token"},
	})
	if err != nil {
		return fmt.Errorf("apple: revoke: %w", err)
	}
	return nil
}

// post sends a form to Apple with the client credentials added and returns the body of a 200 response.
func (c *Client) post(ctx context.Context, path, clientID string, form url.Values) ([]byte, error) {
	secret, err := c.clientSecret(clientID)
	if err != nil {
		return nil, err
	}
	form.Set("client_id", clientID)
	form.Set("client_secret", secret)

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL+path, strings.NewReader(form.Encode()))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")

	resp, err := c.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("HTTP %d: %s", resp.StatusCode, body)
	}
	return body, nil
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
