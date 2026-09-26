// Package appstore verifies the App Store's signed data (JWS): a purchase the app hands over, or a server
// notification. Signatures chain to Apple Root CA - G3, embedded here (SHA-256 63:34:3A:BF:…:91:79, as published at
// apple.com/certificateauthority).
package appstore

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/sha256"
	"crypto/x509"
	_ "embed"
	"encoding/asn1"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"math/big"
	"strings"
	"time"
)

//go:embed AppleRootCA-G3.cer
var appleRootG3 []byte

const maxChain = 4

var (
	// Apple marks the certificates that sign App Store data with these extensions.
	leafMarker         = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 6, 11, 1}
	intermediateMarker = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 6, 2, 1}
)

// Verifier checks signatures against its roots: Apple's in production, a test root in tests.
type Verifier struct {
	roots *x509.CertPool
	now   func() time.Time
}

func New() *Verifier {
	root, err := x509.ParseCertificate(appleRootG3)
	if err != nil {
		panic(fmt.Sprintf("appstore: embedded Apple root: %v", err))
	}
	return NewWithRoot(root, time.Now)
}

func NewWithRoot(root *x509.Certificate, now func() time.Time) *Verifier {
	pool := x509.NewCertPool()
	pool.AddCert(root)
	return &Verifier{roots: pool, now: now}
}

// Transaction is the part of a signed transaction befriend uses.
type Transaction struct {
	TransactionID         string `json:"transactionId"`
	OriginalTransactionID string `json:"originalTransactionId"`
	BundleID              string `json:"bundleId"`
	ProductID             string `json:"productId"`
	PurchaseDate          int64  `json:"purchaseDate"` // Unix milliseconds
	RevocationDate        int64  `json:"revocationDate"`
	Environment           string `json:"environment"` // Production | Sandbox | Xcode
}

// Notification is an App Store Server Notification (v2) payload.
type Notification struct {
	NotificationType string `json:"notificationType"` // e.g. REFUND, REVOKE
	Data             struct {
		BundleID              string `json:"bundleId"`
		Environment           string `json:"environment"`
		SignedTransactionInfo string `json:"signedTransactionInfo"`
	} `json:"data"`
}

func (v *Verifier) Transaction(signed string) (*Transaction, error) {
	var t Transaction
	return &t, v.decode(signed, &t)
}

func (v *Verifier) Notification(signed string) (*Notification, error) {
	var n Notification
	return &n, v.decode(signed, &n)
}

// decode verifies a compact JWS and unmarshals its payload into out.
func (v *Verifier) decode(signed string, out any) error {
	parts := strings.Split(signed, ".")
	if len(parts) != 3 {
		return fmt.Errorf("appstore: not a compact JWS")
	}
	var header struct {
		Alg string   `json:"alg"`
		X5C []string `json:"x5c"`
	}
	if err := decodeSegment(parts[0], &header); err != nil {
		return err
	}
	// Apple sends leaf, intermediate and root; capping the count bounds the parsing an unsigned request can cause.
	if header.Alg != "ES256" || len(header.X5C) < 2 || len(header.X5C) > maxChain {
		return fmt.Errorf("appstore: want ES256 with a certificate chain")
	}
	leaf, err := v.verifyChain(header.X5C)
	if err != nil {
		return err
	}
	key, ok := leaf.PublicKey.(*ecdsa.PublicKey)
	if !ok {
		return fmt.Errorf("appstore: the signing key isn't ECDSA")
	}
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil || len(sig) != 64 {
		return fmt.Errorf("appstore: malformed signature")
	}
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	if !ecdsa.Verify(key, digest[:], new(big.Int).SetBytes(sig[:32]), new(big.Int).SetBytes(sig[32:])) {
		return fmt.Errorf("appstore: bad signature")
	}
	return decodeSegment(parts[1], out)
}

func (v *Verifier) verifyChain(x5c []string) (*x509.Certificate, error) {
	certs := make([]*x509.Certificate, 0, len(x5c))
	for _, raw := range x5c {
		der, err := base64.StdEncoding.DecodeString(raw)
		if err != nil {
			return nil, fmt.Errorf("appstore: malformed certificate")
		}
		cert, err := x509.ParseCertificate(der)
		if err != nil {
			return nil, fmt.Errorf("appstore: %w", err)
		}
		certs = append(certs, cert)
	}
	leaf, intermediate := certs[0], certs[1]
	if !hasExtension(leaf, leafMarker) || !hasExtension(intermediate, intermediateMarker) {
		return nil, fmt.Errorf("appstore: not an App Store signing chain")
	}
	// ponytail: expiry only, no OCSP/CRL revocation check (Apple's own libraries skip it too); add it if Apple
	// ever revokes a signing certificate mid-validity.
	intermediates := x509.NewCertPool()
	intermediates.AddCert(intermediate)
	_, err := leaf.Verify(x509.VerifyOptions{
		Roots: v.roots, Intermediates: intermediates, CurrentTime: v.now(),
		KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageAny},
	})
	if err != nil {
		return nil, fmt.Errorf("appstore: %w", err)
	}
	return leaf, nil
}

func hasExtension(cert *x509.Certificate, oid asn1.ObjectIdentifier) bool {
	for _, ext := range cert.Extensions {
		if ext.Id.Equal(oid) {
			return true
		}
	}
	return false
}

func decodeSegment(segment string, out any) error {
	raw, err := base64.RawURLEncoding.DecodeString(segment)
	if err != nil {
		return fmt.Errorf("appstore: malformed segment")
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	if err := decoder.Decode(out); err != nil {
		return fmt.Errorf("appstore: %w", err)
	}
	return nil
}

// AppleRootG3 is the embedded root's DER, for checking which certificate ships.
func AppleRootG3() []byte { return appleRootG3 }
