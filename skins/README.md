# Skins

Each folder is one character skin as text pixel grids; the format is documented in
`backend/pkg/skinpack/source.go`. Every skin draws all 20 vocabulary actions, a `walk` cycle heading right (the Mac
mirrors it to walk left), a face per mood, and a 16×16 head per mood for the Dynamic Island and the menu bar.

- `pixel-cat` ships inside the apps (PetCore's `Resources/pixel-cat.zip`); everyone has it.
- `pixel-dog` and later skins are published to the backend and granted per account.

From `backend/`:

```bash
# built-in skin: rebuild after editing skins/pixel-cat (a Go test fails while it's stale)
go run ./cmd/apiserver skin build ../skins/pixel-cat -o ../PetCore/Sources/PetCore/Resources/pixel-cat.zip

# downloadable skins (uses the DB_* settings; point them at the target database)
go run ./cmd/apiserver skin publish ../skins/pixel-dog
go run ./cmd/apiserver skin grant  --skin pixel-dog --email someone@example.com
go run ./cmd/apiserver skin revoke --skin pixel-dog --email someone@example.com   # or --user-id
```

To preview a skin in the Lottie skill's player (github.com/diffusionstudio/lottie), copy `skin.json` from the
built zip to `public/projects/befriend/<scene-N>/lottie.json`; each action is a marker.
