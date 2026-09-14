package skinpack

import (
	"bytes"
	"os"
	"testing"
)

// The repo's skins must build, and PetCore's built-in skin must be the current build of skins/pixel-cat
// (rebuild it with: apiserver skin build ../skins/pixel-cat -o ../PetCore/Sources/PetCore/Resources/pixel-cat.zip).
func TestRepoSkins(t *testing.T) {
	for _, id := range []string{"pixel-cat", "pixel-dog"} {
		t.Run(id, func(t *testing.T) {
			pkg, err := Build("../../../skins/" + id)
			if err != nil {
				t.Fatal(err)
			}
			if pkg.ID != id {
				t.Errorf("meta id %q; want the folder name %q", pkg.ID, id)
			}
			if id != "pixel-cat" {
				return
			}
			bundled, err := os.ReadFile("../../../PetCore/Sources/PetCore/Resources/pixel-cat.zip")
			if err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(bundled, pkg.Zip) {
				t.Error("PetCore's pixel-cat.zip is stale; rebuild it from skins/pixel-cat")
			}
		})
	}
}
