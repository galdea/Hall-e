-- Additive schema for the independent account service. Apply to its dedicated D1 DB.
CREATE TABLE IF NOT EXISTS account_users (
  user_id TEXT PRIMARY KEY NOT NULL
);
CREATE TABLE IF NOT EXISTS account_emails (
  email TEXT PRIMARY KEY NOT NULL,
  user_id TEXT NOT NULL REFERENCES account_users(user_id)
);
CREATE TABLE IF NOT EXISTS account_identities (
  provider TEXT NOT NULL,
  subject TEXT NOT NULL,
  user_id TEXT NOT NULL REFERENCES account_users(user_id),
  PRIMARY KEY (provider, subject),
  UNIQUE (user_id, provider)
);
CREATE TABLE IF NOT EXISTS account_sessions (
  session_id TEXT PRIMARY KEY NOT NULL,
  token_digest TEXT NOT NULL UNIQUE,
  user_id TEXT NOT NULL REFERENCES account_users(user_id),
  expires_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS account_sessions_expiry ON account_sessions(expires_at);
CREATE TABLE IF NOT EXISTS account_auth_challenges (
  challenge_id TEXT PRIMARY KEY NOT NULL,
  provider TEXT NOT NULL,
  link_session TEXT,
  email TEXT,
  proof TEXT NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0,
  expires_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS account_challenge_expiry ON account_auth_challenges(expires_at);
CREATE TABLE IF NOT EXISTS account_auth_limits (
  bucket TEXT PRIMARY KEY NOT NULL,
  used INTEGER NOT NULL,
  expires_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS account_limit_expiry ON account_auth_limits(expires_at);
