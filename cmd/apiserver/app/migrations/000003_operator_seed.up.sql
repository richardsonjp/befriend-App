-- ==========================================
-- OPERATOR & BACKOFFICE SEED
-- ==========================================

-- ==========================================
-- 1. DEFINE PERMISSION CATEGORIES
-- Added 'Settings' here because you referenced it in the Role Assignment later
-- ==========================================
INSERT INTO permission_category (name, description, icon, target_user_type, display_order)
VALUES
    ('Backoffice', 'System administration', 'settings', 'OPERATOR', 90),
    ('Compliance', 'KYC and AML compliance', 'shield', 'OPERATOR', 91),
    ('Settings',   'Operator Account Settings', 'tool',   'OPERATOR', 92);

-- ==========================================
-- 2. DEFINE PERMISSIONS
-- Using INSERT...SELECT for consistency and safety
-- ==========================================
WITH cats AS (
    SELECT id, name
    FROM permission_category
    WHERE target_user_type = 'OPERATOR'
)
INSERT INTO permission (code, name, description, category_id)
-- Backoffice Permissions
SELECT 'OPERATOR_READ', 'View Operators', 'Can view list of operators', id
FROM cats WHERE name = 'Backoffice'
UNION ALL
SELECT 'OPERATOR_WRITE', 'Manage Operators', 'Can create/edit operators', id
FROM cats WHERE name = 'Backoffice'

UNION ALL

-- Compliance Permissions
SELECT 'KYC_READ', 'View KYC', 'Can view KYC requests', id
FROM cats WHERE name = 'Compliance'
UNION ALL
SELECT 'KYC_DECIDE', 'Review KYC', 'Can approve/reject KYC', id
FROM cats WHERE name = 'Compliance'

UNION ALL

-- Settings Permissions (Added to match your Role assignment logic)
SELECT 'OP_SETTINGS_VIEW', 'View Settings', 'View Operator Settings', id
FROM cats WHERE name = 'Settings';

-- ==========================================
-- 3. INSERT APP RESOURCES
-- ==========================================
INSERT INTO app_resource (type, path_pattern, method, name, required_permission_id)
VALUES
    -- Operator Management
    ('BACKEND', '/api/backoffice/operators', 'GET',  'List Operators',
     (SELECT id FROM permission WHERE code = 'OPERATOR_READ')),
    ('BACKEND', '/api/backoffice/operators', 'POST', 'Create Operator',
     (SELECT id FROM permission WHERE code = 'OPERATOR_WRITE')),

    -- KYC Management
    ('BACKEND', '/api/backoffice/kyc',       'GET',  'List KYC Requests',
     (SELECT id FROM permission WHERE code = 'KYC_READ')),
    ('BACKEND', '/api/backoffice/kyc/:id',   'PUT',  'Review KYC',
     (SELECT id FROM permission WHERE code = 'KYC_DECIDE'));

-- ==========================================
-- 4. CREATE ROLES
-- ==========================================
INSERT INTO role (name, description, is_system_role, account_id)
VALUES
    ('Super Admin', 'Full access to all backoffice functions', TRUE, NULL),
    ('KYC Officer', 'Focus on Compliance and KYC reviews',     TRUE, NULL);

-- ==========================================
-- 5. ASSIGN PERMISSIONS TO ROLES
-- Fixed: Uses JOIN to ensure we ONLY assign 'OPERATOR' permissions.
-- ==========================================

-- 5a. Super Admin (Gets Backoffice, Compliance, AND Settings)
INSERT INTO role_permission (role_id, permission_id)
SELECT r.id, p.id
FROM role r
         CROSS JOIN permission p
         JOIN permission_category pc ON p.category_id = pc.id
WHERE r.name = 'Super Admin'
  AND pc.target_user_type = 'OPERATOR' -- <--- CRITICAL SAFETY CHECK
  AND pc.name IN ('Backoffice', 'Compliance', 'Settings');

-- 5b. KYC Officer (Gets ONLY Compliance)
INSERT INTO role_permission (role_id, permission_id)
SELECT r.id, p.id
FROM role r
         CROSS JOIN permission p
         JOIN permission_category pc ON p.category_id = pc.id
WHERE r.name = 'KYC Officer'
  AND pc.target_user_type = 'OPERATOR'
  AND pc.name = 'Compliance';

-- ==========================================
-- 6. CREATE DEFAULT OPERATOR
-- ==========================================
INSERT INTO operator (email, password_hash, full_name, role_id, is_active)
VALUES (
    'admin@example.com',
    '$2a$10$3QxDjD1ORc1yLiJp.m7lT.w8j4l6.x5r9x3x5x5x5x5x5x5x5x5x', -- Ensure this is a valid Bcrypt hash
    'System Administrator',
    (SELECT id FROM role WHERE name = 'Super Admin'),
    TRUE
);