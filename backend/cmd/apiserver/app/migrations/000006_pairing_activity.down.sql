DROP TABLE IF EXISTS trigger_event;
ALTER TABLE "user"
    DROP COLUMN IF EXISTS log_sync_paused,
    DROP COLUMN IF EXISTS excluded_apps;
DROP TABLE IF EXISTS pairing_code;
