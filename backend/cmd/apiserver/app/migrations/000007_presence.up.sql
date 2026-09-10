-- Which device holds the friend right now: the iPhone while its app claims it, else an active Mac, else the iPhone.
CREATE TABLE presence (
    user_id UUID PRIMARY KEY REFERENCES "user"(id) ON DELETE CASCADE,
    owner VARCHAR(10) NOT NULL DEFAULT 'phone',  -- phone | mac
    phone_claim_until TIMESTAMPTZ,                -- the iPhone app is open (renewed every minute)
    mac_active BOOLEAN NOT NULL DEFAULT FALSE,     -- the Mac's user is at the keyboard
    mac_seen_at TIMESTAMPTZ,                       -- last Mac heartbeat
    changed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), -- owner last changed
    last_push_at TIMESTAMPTZ                       -- last APNs push about it (debounced)
);

CREATE INDEX idx_presence_mac_seen ON presence(mac_seen_at) WHERE mac_active;
