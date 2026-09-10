-- APNs tokens uploaded by the iPhone app: Live Activity push-to-start and update tokens, and the widget token.
-- Tokens are tied to the APNs environment the build uses (sandbox for development builds).
ALTER TABLE device
    ADD COLUMN apns_env VARCHAR(10),                -- sandbox | production
    ADD COLUMN la_push_to_start_token VARCHAR(512),
    ADD COLUMN la_push_token VARCHAR(512),          -- the running Live Activity's update token
    ADD COLUMN la_started_at TIMESTAMPTZ,           -- when that activity started (activities end after 8 hours)
    ADD COLUMN widget_push_token VARCHAR(512);
