-- M9: paid skins. A priced skin sells as one In-App Purchase product (non-consumable) in its price tier; the app
-- hands the signed purchase to the backend, which checks it with Apple's signature and grants the skin.
ALTER TABLE skin ADD COLUMN tier SMALLINT CHECK (tier BETWEEN 1 AND 9); -- NULL: not for sale (granted only)
ALTER TABLE skin ADD COLUMN product_id VARCHAR(100);                    -- its current product
ALTER TABLE skin ADD COLUMN preview BYTEA;                              -- frames/idle/0.png, for the shop

-- Every product a skin ever sold as: a skin moved to another tier gets a new product, and earlier purchases of
-- the old one still resolve. Product ids are never reused (App Store Connect doesn't allow it either).
CREATE TABLE skin_product (
    product_id VARCHAR(100) PRIMARY KEY,
    skin_id VARCHAR(40) NOT NULL REFERENCES skin(id) ON DELETE CASCADE,
    tier SMALLINT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- One row per App Store purchase: it unlocks the skin for the befriend account that first presented it.
CREATE TABLE skin_purchase (
    original_transaction_id VARCHAR(64) PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
    skin_id VARCHAR(40) NOT NULL REFERENCES skin(id) ON DELETE CASCADE,
    product_id VARCHAR(100) NOT NULL,
    environment VARCHAR(16) NOT NULL,
    purchased_at TIMESTAMPTZ NOT NULL,
    revoked_at TIMESTAMPTZ, -- refunded or revoked: the grant is taken back
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_skin_purchase_user ON skin_purchase(user_id);

-- A grant a purchase made (a refund takes it back) versus one an admin gave (a refund leaves it).
ALTER TABLE skin_grant ADD COLUMN purchased BOOLEAN NOT NULL DEFAULT FALSE;
