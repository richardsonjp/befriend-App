CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ==========================================
-- 1. PERMISSIONS & RESOURCES
-- ==========================================

CREATE TABLE permission_category (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name VARCHAR(100) NOT NULL,
    description TEXT,
    icon VARCHAR(50),
    target_user_type VARCHAR(20) DEFAULT 'USER', -- 'USER' or 'OPERATOR'
    display_order INT DEFAULT 0,
    UNIQUE(name, target_user_type)
);

CREATE TABLE permission (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    category_id UUID REFERENCES permission_category(id),
    code VARCHAR(100) NOT NULL UNIQUE,
    name VARCHAR(100) NOT NULL,
    description TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE app_resource (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    type VARCHAR(20) NOT NULL, -- Logic handled in App (FRONTEND/BACKEND)
    path_pattern VARCHAR(255) NOT NULL,
    method VARCHAR(10),
    name VARCHAR(100),
    required_permission_id UUID REFERENCES permission(id),
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ==========================================
-- 2. IDENTITY & TENANTS
-- ==========================================

CREATE TABLE "user" (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email VARCHAR(255) UNIQUE NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    full_name VARCHAR(100),
    phone_number VARCHAR(20) UNIQUE,
    status VARCHAR(20) DEFAULT 'unverified',
    email_verified_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE account (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    type VARCHAR(50) NOT NULL, -- Logic handled in App (PERSONAL/CORPORATE)
    name VARCHAR(255),
    max_members INT DEFAULT 3,
    is_frozen BOOLEAN DEFAULT FALSE,
    kyc_level INT DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ==========================================
-- 3. ROLES (RBAC)
-- ==========================================

CREATE TABLE role (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id UUID REFERENCES account(id) ON DELETE CASCADE,
    name VARCHAR(100) NOT NULL,
    description TEXT,
    is_system_role BOOLEAN DEFAULT FALSE,
    UNIQUE (account_id, name)
);

CREATE TABLE role_permission (
    role_id UUID REFERENCES role(id) ON DELETE CASCADE,
    permission_id UUID REFERENCES permission(id) ON DELETE CASCADE,
    PRIMARY KEY (role_id, permission_id)
);

CREATE TABLE account_member (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id UUID REFERENCES account(id) ON DELETE CASCADE,
    user_id UUID REFERENCES "user"(id) ON DELETE CASCADE,
    role_id UUID REFERENCES role(id),
    joined_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(account_id, user_id)
);

-- ==========================================
-- 4. BACKOFFICE (OPERATORS)
-- ==========================================

CREATE TABLE operator (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email VARCHAR(255) UNIQUE NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    full_name VARCHAR(100),
    role_id UUID REFERENCES role(id),
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE operator_audit_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    operator_id UUID REFERENCES operator(id),
    action VARCHAR(50) NOT NULL,
    target_table VARCHAR(50),
    target_id UUID,
    details JSONB,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ==========================================
-- 5. COMPLIANCE (KYC)
-- ==========================================

CREATE TABLE kyc_request (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id UUID REFERENCES account(id) NOT NULL,
    type VARCHAR(50) NOT NULL,
    primary_id_number VARCHAR(50),
    legal_name VARCHAR(255),
    entity_data JSONB NOT NULL DEFAULT '{}',
    documents JSONB NOT NULL DEFAULT '{}',
    section_feedback JSONB DEFAULT '{}',
    status VARCHAR(50) DEFAULT 'PENDING',
    global_rejection_reason TEXT,
    reviewed_by_operator_id UUID REFERENCES operator(id),
    submitted_at TIMESTAMPTZ DEFAULT NOW(),
    reviewed_at TIMESTAMPTZ
);

-- Note: Smart indexes are still useful as they are structural, not procedural logic.
CREATE INDEX idx_kyc_data ON kyc_request USING GIN (entity_data);
CREATE INDEX idx_kyc_identity_search ON kyc_request(primary_id_number);
CREATE UNIQUE INDEX idx_unique_approved_identity ON kyc_request (primary_id_number) WHERE status = 'APPROVED';

-- ==========================================
-- 6. SECURITY
-- ==========================================

CREATE TABLE refresh_token (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES "user"(id) ON DELETE CASCADE,
    operator_id UUID REFERENCES operator(id) ON DELETE CASCADE,
    token_hash VARCHAR(255) NOT NULL UNIQUE,
    device_info VARCHAR(255),
    ip_address INET,
    expires_at TIMESTAMPTZ NOT NULL,
    revoked_at TIMESTAMPTZ, -- Added for Audit (Soft Delete)
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE verification_code (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES "user"(id) ON DELETE CASCADE,
    table_type VARCHAR(50) NOT NULL, -- 'user.email', 'user.phone', 'transaction', etc. (use table name as prefix, column name as suffix, e.g. 'user.email')
    code VARCHAR(10) NOT NULL, -- The 6-digit code (e.g., '123456')
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),

    -- Ensure a user doesn't have 50 active codes (spam protection)
    -- We can enforce logic in app, but an index helps lookup
    UNIQUE(user_id, table_type, code)
);

-- Index for fast lookup during verification
CREATE INDEX idx_verification_lookup ON verification_code(user_id, code, table_type);

-- ==========================================
-- 7. MARKET & ASSETS
-- ==========================================

CREATE TABLE asset (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    symbol VARCHAR(20) UNIQUE NOT NULL,
    name VARCHAR(100),
    type VARCHAR(50) NOT NULL,
    precision INT DEFAULT 2,
    is_tradable BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE market_price (
    asset_id UUID REFERENCES asset(id),
    price DECIMAL(24, 8) NOT NULL,
    captured_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (asset_id, captured_at)
);

-- ==========================================
-- 8. WALLETS & LEDGER
-- ==========================================

CREATE TABLE wallet (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id UUID REFERENCES account(id) NOT NULL,
    asset_id UUID REFERENCES asset(id) NOT NULL,
    balance DECIMAL(24, 8) DEFAULT 0,
    locked_balance DECIMAL(24, 8) DEFAULT 0,
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(account_id, asset_id)
);

CREATE TABLE transaction (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    wallet_id UUID REFERENCES wallet(id) NOT NULL,
    reference_id VARCHAR(100),
    type VARCHAR(50) NOT NULL,
    amount DECIMAL(24, 8) NOT NULL,
    balance_after DECIMAL(24, 8) NOT NULL,
    description TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Basic Indexes
CREATE INDEX idx_transaction_wallet ON transaction(wallet_id);
CREATE INDEX idx_market_price_asset ON market_price(asset_id, captured_at DESC);