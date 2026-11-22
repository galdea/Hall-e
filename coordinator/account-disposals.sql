-- R2 objects outliving a deleted account. A row carries only the opaque blob ID and size,
-- never an owner, so it does not depend on the rows the deletion removed. The Worker and cron drain it.
CREATE TABLE IF NOT EXISTS account_disposals (
    blob_id TEXT PRIMARY KEY NOT NULL,
    size INTEGER NOT NULL,
    queued_at INTEGER NOT NULL
);
