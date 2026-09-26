// Package appstoretest signs App Store-style JWS with a throwaway certificate chain, for tests.
package appstoretest

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/asn1"
	"encoding/base64"
	"encoding/json"
	"math/big"
	"testing"
	"time"
)

var (
	LeafMarker         = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 6, 11, 1}
	IntermediateMarker = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 6, 2, 1}
)

type Cert struct {
	Cert *x509.Certificate
	Key  *ecdsa.PrivateKey
}

// Chain is a root, an intermediate and a leaf marked like Apple's.
type Chain struct{ Root, Intermediate, Leaf *Cert }

func NewChain(t testing.TB) Chain {
	root := Issue(t, "Test Root", nil, true, nil)
	intermediate := Issue(t, "Test WWDR", root, true, IntermediateMarker)
	return Chain{root, intermediate, Issue(t, "Test Signer", intermediate, false, LeafMarker)}
}

// Sign signs payload with the chain's leaf, carrying the whole chain in x5c.
func (c Chain) Sign(t testing.TB, payload any) string {
	return Sign(t, c.Leaf, []*Cert{c.Leaf, c.Intermediate, c.Root}, payload)
}

func Issue(t testing.TB, name string, parent *Cert, ca bool, marker asn1.ObjectIdentifier) *Cert {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(time.Now().UnixNano()), Subject: pkix.Name{CommonName: name},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour),
		IsCA: ca, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature,
	}
	if marker != nil {
		tmpl.ExtraExtensions = []pkix.Extension{{Id: marker, Value: []byte{5, 0}}}
	}
	signer, signerCert := key, tmpl
	if parent != nil {
		signer, signerCert = parent.Key, parent.Cert
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, signerCert, &key.PublicKey, signer)
	if err != nil {
		t.Fatal(err)
	}
	cert, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	return &Cert{cert, key}
}

func Sign(t testing.TB, leaf *Cert, chain []*Cert, payload any) string {
	t.Helper()
	x5c := []string{}
	for _, c := range chain {
		x5c = append(x5c, base64.StdEncoding.EncodeToString(c.Cert.Raw))
	}
	header, _ := json.Marshal(map[string]any{"alg": "ES256", "x5c": x5c})
	body, _ := json.Marshal(payload)
	input := base64.RawURLEncoding.EncodeToString(header) + "." + base64.RawURLEncoding.EncodeToString(body)
	digest := sha256.Sum256([]byte(input))
	r, s, err := ecdsa.Sign(rand.Reader, leaf.Key, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	sig := make([]byte, 64)
	r.FillBytes(sig[:32])
	s.FillBytes(sig[32:])
	return input + "." + base64.RawURLEncoding.EncodeToString(sig)
}
