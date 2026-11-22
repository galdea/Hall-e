-- Applied after account-recording. A formatted transcript over 512 KiB, up to 8 MiB, is kept in R2
-- at recordings/<blob_id>/transcript. This row marks it and records its UTF-8 size.
CREATE TABLE IF NOT EXISTS account_recording_transcripts (
    blob_id TEXT PRIMARY KEY NOT NULL REFERENCES account_recordings(blob_id) ON DELETE CASCADE,
    bytes INTEGER NOT NULL
);
