-- befriend base schema: accounts, devices, sessions, email verification.

CREATE TABLE "user" (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email VARCHAR(255),         -- NULL for Apple/Google accounts without a verified email
    password_hash VARCHAR(255), -- NULL for Apple/Google-only accounts
    status VARCHAR(20) NOT NULL DEFAULT 'unverified',
    email_verified_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Case-insensitive uniqueness; NULL emails never collide.
CREATE UNIQUE INDEX idx_user_email_lower ON "user" (lower(email));

CREATE TABLE device (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
    platform VARCHAR(10) NOT NULL, -- ios | macos
    name VARCHAR(100) NOT NULL,
    last_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_device_user ON device(user_id);

CREATE TABLE refresh_token (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
    device_id UUID NOT NULL REFERENCES device(id) ON DELETE CASCADE,
    token_hash CHAR(64) NOT NULL UNIQUE, -- sha256 hex of the refresh token
    expires_at TIMESTAMPTZ NOT NULL,
    rotated_at TIMESTAMPTZ,
    revoked_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_refresh_token_device ON refresh_token(device_id);

CREATE TABLE verification_code (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
    table_type VARCHAR(50) NOT NULL, -- e.g. 'user.email verification'
    code VARCHAR(10) NOT NULL,
    attempts INT NOT NULL DEFAULT 0,
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (user_id, table_type, code)
);

CREATE INDEX idx_verification_lookup ON verification_code(user_id, table_type);
