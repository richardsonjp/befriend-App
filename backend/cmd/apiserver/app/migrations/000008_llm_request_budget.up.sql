-- LLM request counters per UTC minute and day, so the personality worker stays under the provider's caps.
CREATE TABLE llm_request_budget (
    window_key VARCHAR(40) PRIMARY KEY, -- minute:YYYYMMDDHHMM | day:YYYYMMDD (UTC)
    used INT NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL     -- end of the window; expired rows are deleted
);

CREATE INDEX idx_llm_request_budget_expires ON llm_request_budget(expires_at);
