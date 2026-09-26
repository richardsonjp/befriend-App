package app

import (
	"context"
	"fmt"
	"os"
	"time"

	"befriend/cmd/apiserver/app/store"
	"befriend/internal/services/skin"
	"befriend/pkg/skinpack"
)

// SkinBuild packs a skin folder into a zip file without touching the database (the built-in skin is committed
// into PetCore this way).
func SkinBuild(dir, out string) {
	pkg := buildSkin(dir)
	exitOnError("skin build", os.WriteFile(out, pkg.Zip, 0o644))
	fmt.Printf("skin build: %s → %s (%d bytes, sha256 %s)\n", pkg.ID, out, len(pkg.Zip), pkg.SHA256)
}

// SkinPublish stores a skin as its next version; apps of accounts using it fetch the update.
func SkinPublish(dir string) {
	pkg := buildSkin(dir)
	store.Init()
	version, changed, err := store.App.SkinService.Publish(context.Background(), pkg, nil)
	exitOnError("skin publish", err)
	if !changed {
		fmt.Printf("skin publish: %s is unchanged at version %d\n", pkg.ID, version)
		return
	}
	fmt.Printf("skin publish: %s version %d (%d bytes)\n", pkg.ID, version, len(pkg.Zip))
}

func SkinGrant(payload skin.GrantPayload) {
	store.Init()
	exitOnError("skin grant", store.App.SkinService.Grant(context.Background(), payload))
	fmt.Printf("skin grant: %s granted\n", payload.SkinID)
}

// SkinRevoke takes a skin away; an account using it falls back to the built-in skin.
func SkinRevoke(payload skin.GrantPayload) {
	store.Init()
	revoked, err := store.App.SkinService.Revoke(context.Background(), payload)
	exitOnError("skin revoke", err)
	if !revoked {
		fmt.Printf("skin revoke: the account didn't have %s\n", payload.SkinID)
		return
	}
	fmt.Printf("skin revoke: %s revoked\n", payload.SkinID)
}

// SkinSubmissions lists what's waiting for review, oldest last.
func SkinSubmissions() {
	store.Init()
	pending, err := store.App.SkinService.ListSubmissions(context.Background(), nil)
	exitOnError("skin submissions", err)
	if len(pending) == 0 {
		fmt.Println("skin submissions: nothing waiting")
		return
	}
	for _, s := range pending {
		fmt.Printf("%s  %-20s %-24q artist %s  %s\n", s.ID, s.SkinID, s.Name, s.ArtistID, s.CreatedAt.Format(time.DateTime))
	}
}

// SkinSubmission saves an upload so it can be unzipped and looked at (or run through `skin build`).
func SkinSubmission(id, out string) {
	store.Init()
	m, err := store.App.SkinService.GetSubmission(context.Background(), id)
	exitOnError("skin submission", err)
	exitOnError("skin submission", os.WriteFile(out, m.Archive, 0o644))
	fmt.Printf("skin submission: %s (%s, %s) → %s\n", m.SkinID, m.Name, m.Status, out)
}

func SkinApprove(id string, tier int) {
	store.Init()
	pkg, version, err := store.App.SkinService.Approve(context.Background(), id)
	exitOnError("skin approve", err)
	fmt.Printf("skin approve: %s published as version %d (%d bytes)\n", pkg.ID, version, len(pkg.Zip))
	if tier == 0 {
		fmt.Println("  not for sale: grant it with `skin grant`, or sell it with `skin price`")
		return
	}
	SkinPrice(pkg.ID, tier)
}

// SkinPrice puts a skin on sale and says which product to create in App Store Connect.
func SkinPrice(skinID string, tier int) {
	store.Init()
	product, err := store.App.SkinService.SetTier(context.Background(), skinID, tier)
	exitOnError("skin price", err)
	if product == "" {
		fmt.Printf("skin price: %s is no longer for sale (owners keep it)\n", skinID)
		return
	}
	fmt.Printf("skin price: %s sells as %s (tier %d)\n", skinID, product, tier)
	fmt.Println("  create it in App Store Connect as a non-consumable at that tier's price, then submit it for review")
}

func SkinReject(id, note string) {
	store.Init()
	exitOnError("skin reject", store.App.SkinService.Reject(context.Background(), id, note))
	fmt.Println("skin reject: done; the artist sees your note")
}

func SetArtist(payload skin.GrantPayload, artist bool) {
	store.Init()
	exitOnError("artist", store.App.SkinService.SetArtist(context.Background(), payload, artist))
	if artist {
		fmt.Println("artist add: the account can submit skins")
	} else {
		fmt.Println("artist remove: the account can no longer submit skins")
	}
}

func buildSkin(dir string) *skinpack.Package {
	pkg, err := skinpack.Build(dir)
	exitOnError("skin build", err)
	return pkg
}

func exitOnError(action string, err error) {
	if err != nil {
		fmt.Fprintf(os.Stderr, "%s: %v\n", action, err)
		os.Exit(1)
	}
}
