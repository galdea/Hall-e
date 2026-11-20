-- Additional short-lived handshake state for system-browser sign-in.
CREATE TABLE IF NOT EXISTS account_browser_attempts (
  poll_hash TEXT PRIMARY KEY,
  state_hash TEXT NOT NULL UNIQUE,
  link_bearer_hash TEXT NOT NULL,
  challenge_id TEXT NOT NULL,
  expires_at INTEGER NOT NULL,
  phase TEXT NOT NULL CHECK (phase IN ('waiting','ready','denied')),
  authorization_code TEXT,
  confirmation_tag TEXT,
  failed_confirmations INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS account_browser_expiry ON account_browser_attempts(expires_at);
