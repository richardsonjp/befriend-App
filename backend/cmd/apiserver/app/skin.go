package app

import (
	"context"
	"fmt"
	"os"

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
	version, changed, err := store.App.SkinService.Publish(context.Background(), pkg)
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
