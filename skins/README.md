# Skins

Each folder is one character skin, drawn as PNG frames. The folder name is the skin's id. File and folder names
are what the skin can do; nothing else lists them.

```
ghost/
  skin.json                      {"name": "Ghost", "fps": 8}
  actions/
    idle/0.png 1.png …           required: the rest pose, plays in any mood
    walk/0.png …                 required: the Mac's walk cycle, heading right (the AI never picks it)
    jump/0.png …                 required: the menu-bar hop
    focus/0.png …                required: focusing alongside you during a pomodoro
    stomp/grumpy/0.png …         optional: an action in one mood only
    idle/grumpy/0.png …          optional: idle when grumpy
  mini/
    default.png                  required: 16×16 head for the Dynamic Island and menu bar
    grumpy.png                   required for every mood folder under actions/
```

- Frames are 32×32 PNGs, any colour, soft alpha allowed. Faces are drawn into the frames.
- Frames play 0, 1, 2… with no gaps. Frame 0 is the still widgets show. Save the same image twice to hold a pose.
- Names: 1–24 of `a-z`, `0-9`, `_`, starting with a letter. `default` is not a mood.
- In the app, a mood the action wasn't drawn for plays the plain action, and an action the skin lacks plays idle.

## Submitting a skin (invited artists)

Zip the skin folder and upload it with your befriend account's access token. The id is what the skin is
published under: 1–40 of `a-z`, `0-9`, `-`, and not another artist's.

```bash
cd ghost && zip -r ../ghost.zip . && cd ..
curl -X POST "https://<api>/api/skins/submissions?skin_id=ghost" \
  -H "Authorization: Bearer <token>" -H "STATIC-API-KEY: <key>" \
  -H "Content-Type: application/zip" --data-binary @ghost.zip
curl "https://<api>/api/skins/submissions" -H "Authorization: Bearer <token>" -H "STATIC-API-KEY: <key>"
```

The upload is checked against this format right away (the error says what's wrong), then waits for review. Up to
3 can wait at once; zips are at most 4 MB. Submitting the same id again after approval is how you ship a new
version.

Reviewing, from `backend/`:

```bash
go run ./cmd/apiserver artist add --email artist@example.com       # invite (artist remove to stop)
go run ./cmd/apiserver skin submissions                             # what's waiting
go run ./cmd/apiserver skin submission <id> -o ghost.zip            # look at it
go run ./cmd/apiserver skin approve <id>                            # publish it as the artist's skin
go run ./cmd/apiserver skin reject <id> --note "The walk stutters." # the artist sees the note
```

## Built-in and granted skins

`pixel-cat` ships inside the apps (PetCore's `Resources/pixel-cat.zip`); everyone has it. Other skins are published
to the backend and granted per account. From `backend/`:

```bash
# built-in skin: rebuild after editing skins/pixel-cat (a Go test fails while it's stale)
go run ./cmd/apiserver skin build ../skins/pixel-cat -o ../PetCore/Sources/PetCore/Resources/pixel-cat.zip

# downloadable skins (uses the DB_* settings; point them at the target database)
go run ./cmd/apiserver skin publish ../skins/pixel-dog
go run ./cmd/apiserver skin grant  --skin pixel-dog --email someone@example.com
go run ./cmd/apiserver skin revoke --skin pixel-dog --email someone@example.com   # or --user-id
```
