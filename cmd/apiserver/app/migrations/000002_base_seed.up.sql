-- ==========================================
-- 1. DEFINE PERMISSION CATEGORIES
-- ==========================================
INSERT INTO permission_category (name, description, icon, target_user_type, display_order)
VALUES
    ('Profile', 'Profile Account', '', 'USER_PERSONAL', 1),
    ('Profile', 'Profile Account', '', 'USER_CORPORATE', 1),
    ('Settings', 'Personal Account Settings', '', 'USER_PERSONAL', 2),
    ('Settings', 'Corporate Account Settings', '', 'USER_CORPORATE', 2);

-- ==========================================
-- 2. DEFINE PERMISSIONS
-- Fix: CTE now selects ALL categories so we can map permissions correctly
-- ==========================================
WITH cats AS (
    SELECT id, name, target_user_type
    FROM permission_category
)
INSERT INTO permission (code, name, description, category_id)
-- ----------------------------
-- PERSONAL PERMISSIONS
-- ----------------------------
SELECT 'PERS_ROLE_VIEW', 'View RBAC Menu', 'Personal RBAC', id
FROM cats WHERE name = 'Settings' AND target_user_type = 'USER_PERSONAL'
UNION ALL
SELECT 'PERS_PROFILE_VIEW', 'View Profile', 'Personal Profile', id
FROM cats WHERE name = 'Profile' AND target_user_type = 'USER_PERSONAL'

UNION ALL

-- ----------------------------
-- CORPORATE PERMISSIONS
-- ----------------------------
SELECT 'CORP_ROLE_VIEW', 'View RBAC Menu', 'Corporate RBAC', id
FROM cats WHERE name = 'Settings' AND target_user_type = 'USER_CORPORATE'
UNION ALL
SELECT 'CORP_PROFILE_VIEW', 'View Profile', 'Corporate Profile', id
FROM cats WHERE name = 'Profile' AND target_user_type = 'USER_CORPORATE';

-- ==========================================
-- 3. INSERT APP RESOURCES
-- ==========================================
INSERT INTO app_resource (type, path_pattern, method, name, required_permission_id)
VALUES
    ('BACKEND', '/api/dashboard/role/rbac-menu', 'GET', 'List Permissions',
     (SELECT id FROM permission WHERE code = 'PERS_ROLE_VIEW')),
    ('BACKEND', '/api/dashboard/role/:id', 'GET', 'Role Details',
     (SELECT id FROM permission WHERE code = 'PERS_ROLE_VIEW')),

    ('BACKEND', '/api/dashboard/role/rbac-menu', 'GET', 'List Permissions',
     (SELECT id FROM permission WHERE code = 'CORP_ROLE_VIEW')),
    ('BACKEND', '/api/dashboard/role/:id', 'GET', 'Role Details',
     (SELECT id FROM permission WHERE code = 'CORP_ROLE_VIEW'));

-- ==========================================
-- 4. CREATE ROLES
-- ==========================================
INSERT INTO role (name, description, is_system_role, account_id)
VALUES
    ('Template: Owner', 'Full control template', TRUE, NULL),
    ('Template: Member', 'Read-only access template', TRUE, NULL);

-- ==========================================
-- 5. ASSIGN PERMISSIONS TO ROLES
-- ==========================================

-- 5a. Assign ALL CORPORATE permissions (Profile + Settings) to 'Template: Owner'
INSERT INTO role_permission (role_id, permission_id)
SELECT r.id, p.id
FROM role r
         CROSS JOIN permission p
         JOIN permission_category pc ON p.category_id = pc.id
WHERE r.name = 'Template: Owner'
  AND pc.target_user_type = 'USER_CORPORATE';

-- 5b. Assign ALL PERSONAL permissions (Profile + Settings) to 'Template: Member'
INSERT INTO role_permission (role_id, permission_id)
SELECT r.id, p.id
FROM role r
         CROSS JOIN permission p
         JOIN permission_category pc ON p.category_id = pc.id
WHERE r.name = 'Template: Member'
  AND pc.target_user_type = 'USER_PERSONAL';