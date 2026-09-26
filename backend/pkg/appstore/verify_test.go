package appstore_test

import (
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"befriend/pkg/appstore"
	"befriend/pkg/appstore/appstoretest"
)

func TestTransaction(t *testing.T) {
	chain := appstoretest.NewChain(t)
	v := appstore.NewWithRoot(chain.Root.Cert, time.Now)
	payload := map[string]any{"transactionId": "2", "originalTransactionId": "1", "bundleId": "com.example",
		"productId": "com.example.skin.t1.001", "purchaseDate": 1790000000000, "environment": "Sandbox"}

	good := chain.Sign(t, payload)
	tx, err := v.Transaction(good)
	if err != nil {
		t.Fatal(err)
	}
	if tx.OriginalTransactionID != "1" || tx.ProductID != "com.example.skin.t1.001" || tx.PurchaseDate != 1790000000000 {
		t.Errorf("transaction = %+v", tx)
	}

	parts := strings.Split(good, ".")
	tampered, _ := json.Marshal(map[string]any{"productId": "com.example.skin.t3.001", "bundleId": "com.example"})
	other := appstoretest.NewChain(t)
	unmarked := appstoretest.Issue(t, "Unmarked", chain.Intermediate, false, nil)
	for name, signed := range map[string]string{
		"a tampered payload":       parts[0] + "." + base64.RawURLEncoding.EncodeToString(tampered) + "." + parts[2],
		"another root":             other.Sign(t, payload),
		"a leaf Apple didn't mark": appstoretest.Sign(t, unmarked, []*appstoretest.Cert{unmarked, chain.Intermediate, chain.Root}, payload),
		"garbage":                  "not.a.jws",
	} {
		if _, err := v.Transaction(signed); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
	expired := appstore.NewWithRoot(chain.Root.Cert, func() time.Time { return time.Now().Add(48 * time.Hour) })
	if _, err := expired.Transaction(good); err == nil {
		t.Error("an expired chain was accepted")
	}
}

func TestAppleRootIsEmbedded(t *testing.T) {
	appstore.New() // panics if the embedded root doesn't parse
	root, err := x509.ParseCertificate(appstore.AppleRootG3())
	if err != nil || root.Subject.CommonName != "Apple Root CA - G3" {
		t.Fatalf("root = %v, %v", root, err)
	}
	if sum := sha256.Sum256(root.Raw); base64.StdEncoding.EncodeToString(sum[:]) != "YzQ6v7iaagPrtX6bP1+nvnxPXHVvMBezqMSIw2U+kXk=" {
		t.Error("the embedded root isn't Apple Root CA - G3 (63:34:3A:BF…)")
	}
}
