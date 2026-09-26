package skin

import (
	"context"
	"testing"
	"time"

	"befriend/config"
	repoSkin "befriend/internal/repositories/skin"
	"befriend/pkg/appstore"
	"befriend/pkg/appstore/appstoretest"
	"befriend/pkg/utils/errors"
	"befriend/pkg/utils/logs"
)

type runNow struct{}

func (runNow) Run(ctx context.Context, fn func(ctx context.Context) error) error { return fn(ctx) }

// purchaseRepo records what the purchase flow does; unused SkinRepo methods panic through the nil interface.
type purchaseRepo struct {
	repoSkin.SkinRepo
	owners   map[string]string // original transaction → user
	granted  map[string]bool   // user/skin
	revoked  map[string]bool
	notified []string
}

func (r *purchaseRepo) SkinForProduct(_ context.Context, productID string) (string, error) {
	if productID == "com.example.skin.t1.001" {
		return "ghost", nil
	}
	return "", errors.From("DATA_NOT_FOUND")
}

func (r *purchaseRepo) ClaimPurchase(_ context.Context, p repoSkin.Purchase) (string, error) {
	if _, ok := r.owners[p.OriginalTransactionID]; !ok {
		r.owners[p.OriginalTransactionID] = p.UserID
	}
	return r.owners[p.OriginalTransactionID], nil
}

func (r *purchaseRepo) GrantPurchased(_ context.Context, userID, skinID string) error {
	r.granted[userID+"/"+skinID] = true
	return nil
}

func (r *purchaseRepo) RevokePurchased(_ context.Context, userID, skinID string) error {
	r.revoked[userID+"/"+skinID] = true
	return nil
}

func (r *purchaseRepo) RevokePurchase(_ context.Context, id string, _ time.Time) (string, string, bool, error) {
	owner, ok := r.owners[id]
	return owner, "ghost", ok, nil
}

func (r *purchaseRepo) NotifyUser(_ context.Context, userID string) error {
	r.notified = append(r.notified, userID)
	return nil
}

func (r *purchaseRepo) Catalog(_ context.Context, userID string) ([]repoSkin.CatalogItem, error) {
	return []repoSkin.CatalogItem{{ID: "ghost", Name: "Ghost", Tier: 1, ProductID: "com.example.skin.t1.001", Owned: r.granted[userID+"/ghost"]}}, nil
}

func TestPurchase(t *testing.T) {
	logs.Init("")
	config.Config.AppStore.BundleID = "com.example"
	config.Config.AppStore.Environments = []string{"Production"}
	chain := appstoretest.NewChain(t)
	repo := &purchaseRepo{owners: map[string]string{}, granted: map[string]bool{}, revoked: map[string]bool{}}
	s := &skinService{txRepo: runNow{}, skinRepo: repo, appStore: appstore.NewWithRoot(chain.Root.Cert, time.Now)}
	tx := func(edit func(map[string]any)) string {
		p := map[string]any{"transactionId": "11", "originalTransactionId": "10", "bundleId": "com.example",
			"productId": "com.example.skin.t1.001", "purchaseDate": 1790000000000, "environment": "Production"}
		if edit != nil {
			edit(p)
		}
		return chain.Sign(t, p)
	}
	ctx := context.Background()

	item, err := s.Purchase(ctx, "alice", tx(nil))
	if err != nil || !item.Owned || !repo.granted["alice/ghost"] || repo.notified[0] != "alice" {
		t.Fatalf("purchase: %+v, %v; granted %v", item, err, repo.granted)
	}
	if _, err := s.Purchase(ctx, "alice", tx(nil)); err != nil {
		t.Errorf("restoring the same purchase: %v", err)
	}
	if _, err := s.Purchase(ctx, "bob", tx(nil)); !errors.Is(err, "PURCHASE_TAKEN") {
		t.Errorf("another account presenting alice's purchase: %v", err)
	}

	for name, edit := range map[string]func(map[string]any){
		"another app":         func(p map[string]any) { p["bundleId"] = "com.other" },
		"a sandbox purchase":  func(p map[string]any) { p["environment"] = "Sandbox" },
		"a refunded purchase": func(p map[string]any) { p["revocationDate"] = 1790000001000 },
		"an unknown product":  func(p map[string]any) { p["productId"] = "com.example.skin.t9.999" },
	} {
		if _, err := s.Purchase(ctx, "carol", tx(func(p map[string]any) { p["originalTransactionId"] = "20"; edit(p) })); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
	if repo.granted["carol/ghost"] {
		t.Error("a rejected purchase granted the skin")
	}

	refund := chain.Sign(t, map[string]any{"notificationType": "REFUND", "data": map[string]any{
		"bundleId": "com.example", "environment": "Production", "signedTransactionInfo": tx(nil)}})
	if err := s.AppStoreNotification(ctx, refund); err != nil || !repo.revoked["alice/ghost"] {
		t.Errorf("refund: %v, revoked %v", err, repo.revoked)
	}
	renewal := chain.Sign(t, map[string]any{"notificationType": "DID_RENEW"})
	if err := s.AppStoreNotification(ctx, renewal); err != nil {
		t.Errorf("an unrelated notification: %v", err)
	}
	if err := s.AppStoreNotification(ctx, "forged.payload.here"); err == nil {
		t.Error("an unsigned notification was accepted")
	}
}
