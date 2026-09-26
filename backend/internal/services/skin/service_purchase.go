package skin

import (
	"context"
	"slices"
	"time"

	"befriend/config"
	repoSkin "befriend/internal/repositories/skin"
	"befriend/pkg/utils/errors"
	"befriend/pkg/utils/logs"
)

const maxTier = 9

type CatalogResponse struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Tier      int    `json:"tier"`
	ProductID string `json:"product_id"`
	Preview   []byte `json:"preview"` // PNG, 32×32 (base64 in JSON)
	Owned     bool   `json:"owned"`
}

func (s *skinService) Catalog(ctx context.Context, userID string) ([]CatalogResponse, error) {
	items, err := s.skinRepo.Catalog(ctx, userID)
	if err != nil {
		return nil, err
	}
	out := make([]CatalogResponse, 0, len(items))
	for _, item := range items {
		out = append(out, CatalogResponse(item))
	}
	return out, nil
}

func (s *skinService) SetTier(ctx context.Context, skinID string, tier int) (string, error) {
	if tier < 0 || tier > maxTier {
		return "", errors.From("BAD_REQUEST").WithDetail("tier is 1-9, or 0 to take the skin off sale")
	}
	var product string
	err := s.txRepo.Run(ctx, func(ctx context.Context) error {
		var err error
		product, err = s.skinRepo.SetProduct(ctx, skinID, tier, config.Config.AppStore.ProductPrefix)
		if errors.Is(err, "DATA_NOT_FOUND") {
			return errors.From("SKIN_NOT_FOUND")
		}
		return err
	})
	return product, err
}

func (s *skinService) Purchase(ctx context.Context, userID, signedTransaction string) (*CatalogResponse, error) {
	tx, err := s.appStore.Transaction(signedTransaction)
	if err != nil {
		logs.Log.Warnf("skin purchase by %s: %v", userID, err)
		return nil, errors.From("PURCHASE_INVALID")
	}
	store := config.Config.AppStore
	switch {
	case tx.BundleID != store.BundleID || !slices.Contains(store.Environments, tx.Environment):
		return nil, errors.From("PURCHASE_INVALID").WithDetail("not a purchase from this app's store")
	case tx.RevocationDate != 0:
		return nil, errors.From("PURCHASE_INVALID").WithDetail("the purchase was refunded")
	case tx.OriginalTransactionID == "":
		return nil, errors.From("PURCHASE_INVALID")
	}

	var skinID string
	err = s.txRepo.Run(ctx, func(ctx context.Context) error {
		var err error
		if skinID, err = s.skinRepo.SkinForProduct(ctx, tx.ProductID); errors.Is(err, "DATA_NOT_FOUND") {
			return errors.From("SKIN_NOT_FOUND")
		} else if err != nil {
			return err
		}
		owner, err := s.skinRepo.ClaimPurchase(ctx, repoSkin.Purchase{
			OriginalTransactionID: tx.OriginalTransactionID, UserID: userID, SkinID: skinID, ProductID: tx.ProductID,
			Environment: tx.Environment, PurchasedAt: time.UnixMilli(tx.PurchaseDate),
		})
		if err != nil {
			return err
		}
		if owner != userID {
			return errors.From("PURCHASE_TAKEN") // already unlocked another befriend account
		}
		if err := s.skinRepo.GrantPurchased(ctx, userID, skinID); err != nil {
			return err
		}
		return s.skinRepo.NotifyUser(ctx, userID)
	})
	if err != nil {
		return nil, err
	}
	catalog, err := s.Catalog(ctx, userID)
	if err != nil {
		return nil, err
	}
	for _, item := range catalog {
		if item.ID == skinID {
			return &item, nil
		}
	}
	return &CatalogResponse{ID: skinID, ProductID: tx.ProductID, Owned: true}, nil // no longer for sale, still owned
}

// AppStoreNotification acts on refunds and revocations; other notification types need nothing. A purchase unlocks
// one befriend account, so a Family Sharing REVOKE takes the skin from whichever account claimed the purchase:
// the notification doesn't say which family member lost access. An admin grant of the same skin is kept.
func (s *skinService) AppStoreNotification(ctx context.Context, signedPayload string) error {
	n, err := s.appStore.Notification(signedPayload)
	if err != nil {
		logs.Log.Warnf("app store notification: %v", err)
		return errors.From("PURCHASE_INVALID")
	}
	if n.NotificationType != "REFUND" && n.NotificationType != "REVOKE" {
		return nil
	}
	tx, err := s.appStore.Transaction(n.Data.SignedTransactionInfo)
	if err != nil {
		logs.Log.Warnf("app store notification %s: %v", n.NotificationType, err)
		return errors.From("PURCHASE_INVALID")
	}
	if tx.BundleID != config.Config.AppStore.BundleID {
		return nil
	}
	return s.txRepo.Run(ctx, func(ctx context.Context) error {
		userID, skinID, found, err := s.skinRepo.RevokePurchase(ctx, tx.OriginalTransactionID, time.Now())
		if err != nil || !found {
			return err
		}
		logs.Log.Infof("skin %s taken back from %s: %s", skinID, userID, n.NotificationType)
		if err := s.skinRepo.RevokePurchased(ctx, userID, skinID); err != nil {
			return err
		}
		return s.skinRepo.NotifyUser(ctx, userID)
	})
}
