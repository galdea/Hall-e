CREATE TABLE IF NOT EXISTS account_recordings (
    user_id TEXT NOT NULL,
    meeting_id TEXT NOT NULL,
    id TEXT NOT NULL,
    blob_id TEXT NOT NULL UNIQUE,
    size INTEGER NOT NULL,
    sha256 TEXT NOT NULL,
    mime_type TEXT NOT NULL,
    provider TEXT NOT NULL,
    region TEXT NOT NULL,
    consent_at INTEGER NOT NULL,
    status TEXT NOT NULL,
    detail TEXT,
    claim TEXT,
    provider_job TEXT,
    transcript TEXT,
    updated_at INTEGER NOT NULL,
    next_at INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY(user_id, meeting_id, id),
    FOREIGN KEY(user_id, meeting_id) REFERENCES account_meetings(user_id, id)
);
CREATE INDEX IF NOT EXISTS idx_recordings_due ON account_recordings(status, next_at);
CREATE TABLE IF NOT EXISTS account_recording_parts (
    blob_id TEXT NOT NULL REFERENCES account_recordings(blob_id) ON DELETE CASCADE,
    part_index INTEGER NOT NULL,
    digest TEXT NOT NULL,
    stored INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY(blob_id, part_index)
);
