package pairing_code

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"strings"
	"time"

	"befriend/internal/model"
	"befriend/pkg/utils/errors"
	customStr "befriend/pkg/utils/strings"
)

const (
	// 32 symbols without look-alikes (no 0/O, 1/I): 8 of them are 40 bits, enough for a 2-minute code behind a
	// rate limit, and the code alone can't sign anyone in without the Mac's poll secret.
	codeAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	codeLength   = 8
	codeTTL      = 2 * time.Minute
	// A confirmed code stays claimable a little past expiry, for a Mac that was mid-poll.
	claimGrace = 30 * time.Second
)

func (s *pairingCodeService) Create(ctx context.Context, payload CreatePayload) (*CreateResponse, error) {
	code, err := randomCode()
	if err != nil {
		return nil, err
	}
	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		return nil, err
	}
	pollSecret := hex.EncodeToString(secret)

	name := cleanName(payload.DeviceName)
	if name == "" {
		name = "Mac"
	}
	expiresAt := time.Now().Add(codeTTL)
	err = s.pairingCodeRepo.Create(ctx, &model.PairingCode{
		CodeHash:       hash(code),
		PollSecretHash: hash(pollSecret),
		DeviceName:     name,
		ExpiresAt:      expiresAt,
	})
	if err != nil {
		return nil, err
	}
	return &CreateResponse{Code: code, PollSecret: pollSecret, ExpiresAt: expiresAt}, nil
}

func (s *pairingCodeService) GetPending(ctx context.Context, code string) (*PendingResponse, error) {
	m, err := s.pairingCodeRepo.GetByCodeHash(ctx, hash(normalizeCode(code)), false)
	if err != nil {
		return nil, err
	}
	if m.ConfirmedAt != nil || m.ConsumedAt != nil || !time.Now().Before(m.ExpiresAt) {
		return nil, errors.From("DATA_NOT_FOUND")
	}
	return &PendingResponse{DeviceName: m.DeviceName, ExpiresAt: m.ExpiresAt}, nil
}

func (s *pairingCodeService) Confirm(ctx context.Context, code, userID string) error {
	return s.txRepo.Run(ctx, func(ctx context.Context) error {
		m, err := s.pairingCodeRepo.GetByCodeHash(ctx, hash(normalizeCode(code)), true)
		if err != nil {
			return err
		}
		now := time.Now()
		if m.ConsumedAt != nil || !now.Before(m.ExpiresAt) {
			return errors.From("DATA_NOT_FOUND")
		}
		if m.ConfirmedAt != nil {
			if m.UserID != nil && *m.UserID == userID {
				return nil // a repeated tap
			}
			return errors.From("DATA_NOT_FOUND")
		}
		return s.pairingCodeRepo.Confirm(ctx, m.ID, userID, now)
	})
}

func (s *pairingCodeService) Claim(ctx context.Context, code, pollSecret string) (*model.PairingCode, error) {
	m, err := s.pairingCodeRepo.GetByCodeHash(ctx, hash(normalizeCode(code)), true)
	if errors.Is(err, "DATA_NOT_FOUND") {
		return nil, errors.From("PAIRING_GONE")
	}
	if err != nil {
		return nil, err
	}

	now := time.Now()
	switch claimStateOf(m, pollSecret, now) {
	case claimPending:
		return nil, nil
	case claimReady:
		if err := s.pairingCodeRepo.MarkConsumed(ctx, m.ID, now); err != nil {
			return nil, err
		}
		return m, nil
	default:
		return nil, errors.From("PAIRING_GONE")
	}
}

func (s *pairingCodeService) DeleteExpired(ctx context.Context, now time.Time) (int64, error) {
	return s.pairingCodeRepo.DeleteExpiredBefore(ctx, now.Add(-24*time.Hour))
}

type claimState int

const (
	claimGone claimState = iota
	claimPending
	claimReady
)

// claimStateOf decides a Mac's poll. A wrong secret looks exactly like an expired code.
func claimStateOf(m *model.PairingCode, pollSecret string, now time.Time) claimState {
	if subtle.ConstantTimeCompare([]byte(m.PollSecretHash), []byte(hash(strings.ToLower(pollSecret)))) != 1 {
		return claimGone
	}
	if m.ConsumedAt != nil {
		return claimGone
	}
	if m.ConfirmedAt == nil {
		if now.Before(m.ExpiresAt) {
			return claimPending
		}
		return claimGone
	}
	if now.Before(m.ExpiresAt.Add(claimGrace)) && m.UserID != nil {
		return claimReady
	}
	return claimGone
}

func randomCode() (string, error) {
	b := make([]byte, codeLength)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	for i := range b {
		b[i] = codeAlphabet[int(b[i])%len(codeAlphabet)] // 256 is a multiple of 32: no bias
	}
	return string(b), nil
}

// normalizeCode accepts codes typed by hand: any case, with spaces or dashes.
func normalizeCode(code string) string {
	return strings.ToUpper(strings.NewReplacer(" ", "", "-", "").Replace(strings.TrimSpace(code)))
}

func hash(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hex.EncodeToString(sum[:])
}

// cleanName keeps the Mac's name to one visible line: the iPhone shows it in "Pair <name>?".
func cleanName(name string) string {
	name = strings.Map(func(r rune) rune {
		if customStr.IsHiddenRune(r) {
			return -1
		}
		return r
	}, name)
	return strings.Join(strings.Fields(name), " ")
}
