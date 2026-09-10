-- Reverse the seed

-- 1. Remove Operators
DELETE FROM operator WHERE email = 'admin@example.com';

-- 2. Remove Roles (Permissions cascade delete)
DELETE FROM role WHERE name IN ('Super Admin', 'KYC Officer');

-- 3. Remove App Resources
DELETE FROM app_resource WHERE path_pattern LIKE '/api/backoffice%';

-- 4. Remove Permissions
DELETE FROM permission WHERE code IN ('OPERATOR_READ', 'OPERATOR_WRITE', 'KYC_READ', 'KYC_DECIDE');

-- 5. Remove Categories
DELETE FROM permission_category WHERE name IN ('Backoffice', 'Compliance');
