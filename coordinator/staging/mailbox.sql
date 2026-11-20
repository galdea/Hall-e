-- Only for the private synthetic staging mailbox. All times are Unix milliseconds.
CREATE TABLE IF NOT EXISTS staging_qa_mailbox (
  email TEXT PRIMARY KEY CHECK(email IN ('halle-owner@example.test','halle-other@example.test')),
  code TEXT NOT NULL CHECK(length(code)=8 AND code NOT GLOB '*[^0-9]*'),
  expires_at INTEGER NOT NULL
);
