-- The bundle ID an Apple refresh token was issued to: revoking it must use the same client_id.
ALTER TABLE user_identity ADD COLUMN apple_client_id VARCHAR(255);
