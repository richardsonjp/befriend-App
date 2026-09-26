-- M9: invited artists upload skins; an admin approves (publishes) or rejects them.
ALTER TABLE "user" ADD COLUMN is_artist BOOLEAN NOT NULL DEFAULT FALSE;

-- Who made a published skin; NULL for skins published from the repo. Only its artist can submit a new version.
ALTER TABLE skin ADD COLUMN artist_user_id UUID REFERENCES "user"(id) ON DELETE SET NULL;

CREATE TABLE skin_submission (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    artist_user_id UUID NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
    skin_id VARCHAR(40) NOT NULL CHECK (skin_id ~ '^[a-z0-9-]+$'),
    name VARCHAR(40) NOT NULL,
    archive BYTEA NOT NULL,                        -- the artist's zipped skin folder, as uploaded
    status VARCHAR(10) NOT NULL DEFAULT 'pending', -- pending | approved | rejected
    note VARCHAR(500),                             -- why it was rejected
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    reviewed_at TIMESTAMPTZ
);
CREATE INDEX idx_skin_submission_pending ON skin_submission(created_at) WHERE status = 'pending';
CREATE INDEX idx_skin_submission_artist ON skin_submission(artist_user_id, created_at DESC);
