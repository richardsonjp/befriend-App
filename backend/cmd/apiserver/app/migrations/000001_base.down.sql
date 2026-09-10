-- Drop all tables and objects in reverse order of creation

-- ==========================================
-- 8. WALLETS & LEDGER
-- ==========================================
DROP INDEX IF EXISTS idx_market_price_asset;
DROP INDEX IF EXISTS idx_transaction_wallet;

DROP TABLE IF EXISTS transaction;
DROP TABLE IF EXISTS wallet;

-- ==========================================
-- 7. MARKET & ASSETS
-- ==========================================
DROP TABLE IF EXISTS market_price;
DROP TABLE IF EXISTS asset;

-- ==========================================
-- 6. SECURITY
-- ==========================================
DROP TABLE IF EXISTS refresh_token;

-- ==========================================
-- 5. COMPLIANCE (KYC)
-- ==========================================
DROP INDEX IF EXISTS idx_unique_approved_identity;
DROP INDEX IF EXISTS idx_kyc_identity_search;
DROP INDEX IF EXISTS idx_kyc_data;

DROP TABLE IF EXISTS kyc_request;

-- ==========================================
-- 4. BACKOFFICE (OPERATORS)
-- ==========================================
DROP TABLE IF EXISTS operator_audit_log;
DROP TABLE IF EXISTS operator;

-- ==========================================
-- 3. ROLES (RBAC)
-- ==========================================
DROP TABLE IF EXISTS account_member;
DROP TABLE IF EXISTS role_permission;
DROP TABLE IF EXISTS role;

-- ==========================================
-- 2. IDENTITY & TENANTS
-- ==========================================
DROP TABLE IF EXISTS account;
DROP TABLE IF EXISTS "user";

-- ==========================================
-- 1. PERMISSIONS & RESOURCES
-- ==========================================
DROP TABLE IF EXISTS app_resource;
DROP TABLE IF EXISTS permission;
DROP TABLE IF EXISTS permission_category;

DROP EXTENSION IF EXISTS "uuid-ossp";