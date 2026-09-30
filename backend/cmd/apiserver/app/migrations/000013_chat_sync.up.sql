-- End-to-end-encrypted chat sync between a user's Mac and iPhone. The server stores opaque ciphertext only; it
-- never reads a blob. Everything cascades with the user, so deleting the account removes it.

-- Fingerprint of the user's chat sync key: devices holding a different key must not upload.
CREATE TABLE chat_sync_keys (
    user_id UUID PRIMARY KEY REFERENCES "user"(id) ON DELETE CASCADE,
    key_id TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Every insert and accepted update takes a new seq, so a device pulls "everything after seq N".
CREATE SEQUENCE chat_records_seq;

CREATE TABLE chat_records (
    user_id UUID NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
    kind TEXT NOT NULL CHECK (kind IN ('conversation', 'document')),
    record_id UUID NOT NULL,
    seq BIGINT NOT NULL,
    modified_at TIMESTAMPTZ NOT NULL,          -- the client's clock: last writer wins
    deleted BOOLEAN NOT NULL DEFAULT FALSE,    -- tombstone: blob NULL, size 0
    blob BYTEA,                                -- ciphertext
    size INT NOT NULL DEFAULT 0,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, kind, record_id)
);

CREATE INDEX idx_chat_records_user_seq ON chat_records(user_id, seq);

-- Handing the sync key from one device to the other: each posts its public key, then the key sealed for the
-- other. Lives 15 minutes.
CREATE TABLE chat_key_exchanges (
    id UUID PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
    mac_public TEXT,
    phone_public TEXT,
    sealed_for_mac TEXT,
    sealed_for_phone TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMPTZ NOT NULL
);

CREATE INDEX idx_chat_key_exchanges_user ON chat_key_exchanges(user_id);
