package skin

import (
	"context"
	"fmt"
	"time"

	"befriend/internal/model"
	"befriend/pkg/utils/errors"
)

// CatalogItem is a skin for sale, with whether the account already has it.
type CatalogItem struct {
	ID        string `gorm:"column:id"`
	Name      string `gorm:"column:name"`
	Tier      int    `gorm:"column:tier"`
	ProductID string `gorm:"column:product_id"`
	Preview   []byte `gorm:"column:preview"`
	Owned     bool   `gorm:"column:owned"`
}

func (r *skinRepo) Catalog(ctx context.Context, userID string) ([]CatalogItem, error) {
	var items []CatalogItem
	err := r.dbdget.Get(ctx).Raw(`
SELECT s.id, s.name, s.tier, s.product_id, s.preview,
       EXISTS (SELECT 1 FROM skin_grant g WHERE g.skin_id = s.id AND g.user_id = ?) AS owned
FROM skin s WHERE s.product_id IS NOT NULL
ORDER BY s.tier, s.name, s.id`, userID).Scan(&items).Error
	return items, err
}

// SetProduct puts a skin on sale in a tier under a new product id (never reused), or takes it off sale (tier 0).
// It returns the product id to create in App Store Connect.
func (r *skinRepo) SetProduct(ctx context.Context, skinID string, tier int, prefix string) (string, error) {
	db := r.dbdget.Get(ctx)
	if tier == 0 {
		q := db.Exec(`UPDATE skin SET tier = NULL, product_id = NULL WHERE id = ?`, skinID)
		return "", notFoundIfNone(q.Error, q.RowsAffected)
	}
	var current []model.Skin
	if err := db.Raw(`SELECT tier, product_id FROM skin WHERE id = ?`, skinID).Scan(&current).Error; err != nil {
		return "", err
	}
	if len(current) == 0 {
		return "", errors.From("DATA_NOT_FOUND")
	}
	if current[0].Tier != nil && *current[0].Tier == tier && current[0].ProductID != nil {
		return *current[0].ProductID, nil
	}
	// One numbering per tier, serialized so two approvals can't take the same slot.
	if err := db.Exec(`SELECT pg_advisory_xact_lock(hashtext(?))`, "skin_product").Error; err != nil {
		return "", err
	}
	// Back in a tier it sold in before: that product already exists in App Store Connect.
	var earlier []string
	if err := db.Raw(`SELECT product_id FROM skin_product WHERE skin_id = ? AND tier = ? ORDER BY created_at LIMIT 1`, skinID, tier).
		Scan(&earlier).Error; err != nil {
		return "", err
	}
	product := ""
	if len(earlier) == 1 {
		product = earlier[0]
	} else {
		var slot int
		if err := db.Raw(`SELECT COUNT(*) + 1 FROM skin_product WHERE tier = ?`, tier).Scan(&slot).Error; err != nil {
			return "", err
		}
		product = fmt.Sprintf("%s.t%d.%03d", prefix, tier, slot)
		if err := db.Exec(`INSERT INTO skin_product (product_id, skin_id, tier) VALUES (?, ?, ?)`, product, skinID, tier).Error; err != nil {
			return "", err
		}
	}
	return product, db.Exec(`UPDATE skin SET tier = ?, product_id = ? WHERE id = ?`, tier, product, skinID).Error
}

func (r *skinRepo) SkinForProduct(ctx context.Context, productID string) (string, error) {
	var ids []string
	if err := r.dbdget.Get(ctx).Raw(`SELECT skin_id FROM skin_product WHERE product_id = ?`, productID).Scan(&ids).Error; err != nil {
		return "", err
	}
	if len(ids) == 0 {
		return "", errors.From("DATA_NOT_FOUND")
	}
	return ids[0], nil
}

// ClaimPurchase records an App Store purchase for the account presenting it and returns who owns it: the first
// account to present a purchase keeps it.
func (r *skinRepo) ClaimPurchase(ctx context.Context, p Purchase) (owner string, err error) {
	db := r.dbdget.Get(ctx)
	err = db.Exec(`
INSERT INTO skin_purchase (original_transaction_id, user_id, skin_id, product_id, environment, purchased_at)
VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT (original_transaction_id) DO NOTHING`,
		p.OriginalTransactionID, p.UserID, p.SkinID, p.ProductID, p.Environment, p.PurchasedAt).Error
	if err != nil {
		return "", err
	}
	var owners []string
	err = db.Raw(`SELECT user_id FROM skin_purchase WHERE original_transaction_id = ? AND revoked_at IS NULL`, p.OriginalTransactionID).
		Scan(&owners).Error
	if err != nil || len(owners) == 0 {
		return "", err // refunded: nobody owns it
	}
	return owners[0], nil
}

// GrantPurchased grants a bought skin, marked as the purchase's; an account that already had it (an admin grant)
// keeps its grant as it was.
func (r *skinRepo) GrantPurchased(ctx context.Context, userID, skinID string) error {
	return r.dbdget.Get(ctx).Exec(`INSERT INTO skin_grant (user_id, skin_id, purchased) VALUES (?, ?, TRUE) ON CONFLICT DO NOTHING`,
		userID, skinID).Error
}

// RevokePurchased takes back a grant only if a purchase made it.
func (r *skinRepo) RevokePurchased(ctx context.Context, userID, skinID string) error {
	return r.dbdget.Get(ctx).Exec(`DELETE FROM skin_grant WHERE user_id = ? AND skin_id = ? AND purchased`, userID, skinID).Error
}

// RevokePurchase marks a refunded or revoked purchase; it returns the account and skin it had unlocked.
func (r *skinRepo) RevokePurchase(ctx context.Context, originalTransactionID string, now time.Time) (userID, skinID string, found bool, err error) {
	var rows []struct {
		UserID string `gorm:"column:user_id"`
		SkinID string `gorm:"column:skin_id"`
	}
	err = r.dbdget.Get(ctx).Raw(`
UPDATE skin_purchase SET revoked_at = ? WHERE original_transaction_id = ? AND revoked_at IS NULL
RETURNING user_id, skin_id`, now, originalTransactionID).Scan(&rows).Error
	if err != nil || len(rows) == 0 {
		return "", "", false, err
	}
	return rows[0].UserID, rows[0].SkinID, true, nil
}

type Purchase struct {
	OriginalTransactionID string
	UserID                string
	SkinID                string
	ProductID             string
	Environment           string
	PurchasedAt           time.Time
}

func notFoundIfNone(err error, rows int64) error {
	if err == nil && rows == 0 {
		return errors.From("DATA_NOT_FOUND")
	}
	return err
}
