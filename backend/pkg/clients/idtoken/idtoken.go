// Package idtoken verifies OpenID Connect ID tokens from Sign in with Apple and Google Sign-In.
package idtoken

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"errors"
	"fmt"
	"slices"
	"time"

	"github.com/MicahParks/keyfunc/v3"
	"github.com/golang-jwt/jwt/v5"
)

const (
	jwksHTTPTimeout = 10 * time.Second
	clockLeeway     = time.Minute
)

type Config struct {
	JWKSURL   string   // provider's public signing keys
	Issuers   []string // accepted "iss" values
	Audiences []string // accepted "aud" values: our bundle IDs / OAuth client IDs
	HashNonce bool     // Apple puts hex(sha256(raw nonce)) in the token; Google puts the raw nonce
}

// Identity is the verified part of an ID token.
type Identity struct {
	Subject       string // provider's stable user id
	Email         string
	EmailVerified bool
	Audience      string // which of our audiences the token was issued for
}

type Verifier struct {
	cfg     Config
	keyfunc jwt.Keyfunc
}

type claims struct {
	jwt.RegisteredClaims
	Email         string      `json:"email"`
	EmailVerified interface{} `json:"email_verified"` // Apple sends "true"/"false", Google a boolean
	Nonce         string      `json:"nonce"`
}

// New returns a nil verifier (and no error) when no audiences are configured. The provider's key set is
// fetched in the background and refreshed hourly; an unreachable provider at startup doesn't fail New.
func New(ctx context.Context, cfg Config) (*Verifier, error) {
	if len(cfg.Audiences) == 0 {
		return nil, nil
	}
	kf, err := keyfunc.NewDefaultOverrideCtx(ctx, []string{cfg.JWKSURL}, keyfunc.Override{HTTPTimeout: jwksHTTPTimeout})
	if err != nil {
		return nil, fmt.Errorf("idtoken: load key set %s: %w", cfg.JWKSURL, err)
	}
	return &Verifier{cfg: cfg, keyfunc: kf.Keyfunc}, nil
}

// Verify checks signature (RS256 only), expiry, issuer, audience and nonce, and returns the identity.
func (v *Verifier) Verify(ctx context.Context, rawToken, nonce string) (*Identity, error) {
	c := &claims{}
	_, err := jwt.ParseWithClaims(rawToken, c, v.keyfunc,
		jwt.WithValidMethods([]string{"RS256"}),
		jwt.WithAudience(v.cfg.Audiences...),
		jwt.WithExpirationRequired(),
		jwt.WithIssuedAt(),
		jwt.WithLeeway(clockLeeway),
	)
	if err != nil {
		return nil, fmt.Errorf("idtoken: %w", err)
	}
	if !slices.Contains(v.cfg.Issuers, c.Issuer) {
		return nil, errors.New("idtoken: unexpected issuer")
	}
	if c.Subject == "" {
		return nil, errors.New("idtoken: missing subject")
	}

	want := nonce
	if v.cfg.HashNonce {
		sum := sha256.Sum256([]byte(nonce))
		want = hex.EncodeToString(sum[:])
	}
	if nonce == "" || subtle.ConstantTimeCompare([]byte(c.Nonce), []byte(want)) != 1 {
		return nil, errors.New("idtoken: nonce mismatch")
	}

	identity := &Identity{Subject: c.Subject, Email: c.Email}
	switch verified := c.EmailVerified.(type) {
	case bool:
		identity.EmailVerified = verified
	case string:
		identity.EmailVerified = verified == "true"
	}
	for _, aud := range c.Audience {
		if slices.Contains(v.cfg.Audiences, aud) {
			identity.Audience = aud
			break
		}
	}
	return identity, nil
}
