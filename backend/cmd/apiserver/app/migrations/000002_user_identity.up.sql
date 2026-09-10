-- Apple/Google sign-in identities linked to a user (one user can have several).
CREATE TABLE user_identity (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
    provider VARCHAR(10) NOT NULL,  -- apple | google
    subject VARCHAR(255) NOT NULL,  -- the provider's stable user id (token "sub")
    email VARCHAR(255),             -- as reported by the provider (may be an Apple private relay address)
    email_verified BOOLEAN NOT NULL DEFAULT FALSE,
    apple_refresh_token TEXT,       -- kept only to revoke Sign in with Apple when the account is deleted
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (provider, subject)
);

CREATE INDEX idx_user_identity_user ON user_identity(user_id);
