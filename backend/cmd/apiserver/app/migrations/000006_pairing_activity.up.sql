-- QR pairing: the Mac shows a short code, a signed-in iPhone confirms it, and the Mac claims its session with the
-- poll secret only it holds. Both are stored hashed.
CREATE TABLE pairing_code (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    code_hash CHAR(64) NOT NULL UNIQUE,                     -- sha256 hex of the code
    poll_secret_hash CHAR(64) NOT NULL,                     -- sha256 hex of the Mac's poll secret
    device_name VARCHAR(100) NOT NULL,
    user_id UUID REFERENCES "user"(id) ON DELETE CASCADE,  -- set when an iPhone confirms
    confirmed_at TIMESTAMPTZ,
    consumed_at TIMESTAMPTZ,                                -- the Mac claimed its session
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_pairing_code_expires ON pairing_code(expires_at);

-- Activity sync settings.
ALTER TABLE "user"
    ADD COLUMN log_sync_paused BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN excluded_apps JSONB NOT NULL DEFAULT '[]';   -- app names never stored

-- The trigger log the Mac (and iPhone) sync; kept 30 days, sent to the LLM for weekly evolution.
CREATE TABLE trigger_event (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
    device_id UUID REFERENCES device(id) ON DELETE SET NULL,
    client_event_id UUID NOT NULL,                          -- makes uploads idempotent
    kind VARCHAR(20) NOT NULL,
    app_name VARCHAR(40),
    seconds INT,
    occurred_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (user_id, client_event_id)
);

CREATE INDEX idx_trigger_event_user_time ON trigger_event(user_id, occurred_at DESC);
CREATE INDEX idx_trigger_event_occurred ON trigger_event(occurred_at);
