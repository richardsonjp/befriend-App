-- ==========================================
-- REVERSE SEEDING
-- ==========================================

-- 1. Remove App Resources (Must delete before permissions due to FK)
DELETE FROM app_resource;

-- 2. Remove Permissions and their links to roles (Cascade handles role_permission)
DELETE FROM permission;

-- 3. Remove Permission Categories
DELETE FROM permission_category;

-- 4. Remove System Roles
DELETE FROM role WHERE is_system_role = TRUE;
