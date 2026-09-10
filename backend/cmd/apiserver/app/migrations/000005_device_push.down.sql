ALTER TABLE device
    DROP COLUMN IF EXISTS apns_env,
    DROP COLUMN IF EXISTS la_push_to_start_token,
    DROP COLUMN IF EXISTS la_push_token,
    DROP COLUMN IF EXISTS la_started_at,
    DROP COLUMN IF EXISTS widget_push_token;
