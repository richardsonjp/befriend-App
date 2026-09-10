// Package apns sends Apple Push Notification service requests over HTTP/2 with token (.p8) authentication.
package apns

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"encoding/json"
	stderrors "errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

const (
	productionURL    = "https://api.push.apple.com"
	sandboxURL       = "https://api.sandbox.push.apple.com"
	requestTimeout   = 10 * time.Second
	providerTokenTTL = 50 * time.Minute // Apple rejects tokens older than an hour and refreshes more often than every 20 minutes
)

type PushType string

const (
	PushTypeLiveActivity PushType = "liveactivity"
	PushTypeWidgets      PushType = "widgets"
)

// ErrUnregistered means the device token will never work again: forget it.
var ErrUnregistered = stderrors.New("apns: device token is no longer valid")

type Config struct {
	TeamID        string
	KeyID         string
	PrivateKeyPEM string // .p8 contents; literal "\n" sequences are accepted
	BundleID      string // the app's bundle ID; topics are "<bundle>.push-type.<type>"
}

type Client struct {
	cfg           Config
	key           *ecdsa.PrivateKey
	http          *http.Client
	productionURL string
	sandboxURL    string

	mu          sync.Mutex
	token       string
	tokenIssued time.Time
}

type Notification struct {
	DeviceToken string
	Sandbox     bool
	PushType    PushType
	Priority    int // 5 (power-friendly) or 10 (immediate)
	Payload     interface{}
}

// New returns a nil client (and no error) when APNs credentials aren't configured.
func New(cfg Config) (*Client, error) {
	if cfg.TeamID == "" || cfg.KeyID == "" || cfg.PrivateKeyPEM == "" || cfg.BundleID == "" {
		return nil, nil
	}
	key, err := jwt.ParseECPrivateKeyFromPEM([]byte(strings.ReplaceAll(cfg.PrivateKeyPEM, `\n`, "\n")))
	if err != nil {
		return nil, fmt.Errorf("apns: invalid private key: %w", err)
	}
	return &Client{
		cfg:           cfg,
		key:           key,
		http:          &http.Client{Timeout: requestTimeout}, // TLS connections negotiate HTTP/2
		productionURL: productionURL,
		sandboxURL:    sandboxURL,
	}, nil
}

func (c *Client) Send(ctx context.Context, n Notification) error {
	body, err := json.Marshal(n.Payload)
	if err != nil {
		return err
	}
	err = c.send(ctx, n, body, false)
	if stderrors.Is(err, errExpiredProviderToken) {
		err = c.send(ctx, n, body, true)
	}
	return err
}

var errExpiredProviderToken = stderrors.New("apns: provider token expired")

func (c *Client) send(ctx context.Context, n Notification, body []byte, freshToken bool) error {
	token, err := c.providerToken(time.Now(), freshToken)
	if err != nil {
		return err
	}
	base := c.productionURL
	if n.Sandbox {
		base = c.sandboxURL
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, base+"/3/device/"+n.DeviceToken, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("authorization", "bearer "+token)
	req.Header.Set("apns-push-type", string(n.PushType))
	req.Header.Set("apns-topic", c.cfg.BundleID+".push-type."+string(n.PushType))
	req.Header.Set("apns-priority", fmt.Sprint(n.Priority))
	req.Header.Set("content-type", "application/json")

	resp, err := c.http.Do(req)
	if err != nil {
		return fmt.Errorf("apns: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusOK {
		return nil
	}

	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<10))
	var reason struct {
		Reason string `json:"reason"`
	}
	_ = json.Unmarshal(raw, &reason)
	switch {
	case resp.StatusCode == http.StatusGone, reason.Reason == "BadDeviceToken", reason.Reason == "Unregistered", reason.Reason == "DeviceTokenNotForTopic":
		return ErrUnregistered
	case reason.Reason == "ExpiredProviderToken" && !freshToken:
		return errExpiredProviderToken
	default:
		return fmt.Errorf("apns: HTTP %d: %s", resp.StatusCode, reason.Reason)
	}
}

// providerToken is the ES256 JWT APNs authenticates with, reused for up to 50 minutes.
func (c *Client) providerToken(now time.Time, fresh bool) (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if !fresh && c.token != "" && now.Sub(c.tokenIssued) < providerTokenTTL {
		return c.token, nil
	}
	token := jwt.NewWithClaims(jwt.SigningMethodES256, jwt.MapClaims{
		"iss": c.cfg.TeamID,
		"iat": now.Unix(),
	})
	token.Header["kid"] = c.cfg.KeyID
	signed, err := token.SignedString(c.key)
	if err != nil {
		return "", err
	}
	c.token, c.tokenIssued = signed, now
	return signed, nil
}
