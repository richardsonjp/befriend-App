-- Character skins: each published skin's zip, the accounts granted it, and the skin each account picked.
CREATE TABLE skin (
    id VARCHAR(40) PRIMARY KEY CHECK (id ~ '^[a-z0-9-]+$'),
    name VARCHAR(40) NOT NULL,
    version INT NOT NULL,          -- bumped whenever the archive changes
    sha256 CHAR(64) NOT NULL,      -- hex digest of archive
    archive BYTEA NOT NULL,        -- zip: manifest.json, skin.json (Lottie), stills/, mini/
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE skin_grant (
    user_id UUID NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
    skin_id VARCHAR(40) NOT NULL REFERENCES skin(id) ON DELETE CASCADE,
    granted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, skin_id)
);

-- NULL = the built-in skin. Only a granted skin can be picked, and revoking the grant clears the pick.
ALTER TABLE "user" ADD COLUMN skin_id VARCHAR(40);
ALTER TABLE "user" ADD CONSTRAINT fk_user_skin_grant FOREIGN KEY (id, skin_id)
    REFERENCES skin_grant (user_id, skin_id) ON DELETE SET NULL (skin_id);
