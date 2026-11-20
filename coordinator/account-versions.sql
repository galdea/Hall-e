-- Applied after account-meetings, account-recording and account-transcripts.
-- Track changes visible to the agenda without fetching audio or transcript text on an idle poll.
CREATE TABLE IF NOT EXISTS account_calendar_versions (
    user_id TEXT PRIMARY KEY,
    version TEXT NOT NULL
);

CREATE TRIGGER IF NOT EXISTS account_version_meeting_insert AFTER INSERT ON account_meetings
BEGIN
    INSERT OR REPLACE INTO account_calendar_versions VALUES (NEW.user_id, lower(hex(randomblob(16))));
END;
CREATE TRIGGER IF NOT EXISTS account_version_meeting_edit AFTER UPDATE OF revision ON account_meetings
BEGIN
    INSERT OR REPLACE INTO account_calendar_versions VALUES (NEW.user_id, lower(hex(randomblob(16))));
END;
CREATE TRIGGER IF NOT EXISTS account_version_audio_insert AFTER INSERT ON account_recordings
BEGIN
    INSERT OR REPLACE INTO account_calendar_versions VALUES (NEW.user_id, lower(hex(randomblob(16))));
END;
CREATE TRIGGER IF NOT EXISTS account_version_audio_change AFTER UPDATE OF status, detail, transcript ON account_recordings
WHEN OLD.status IS NOT NEW.status OR OLD.detail IS NOT NEW.detail OR OLD.transcript IS NOT NEW.transcript
BEGIN
    INSERT OR REPLACE INTO account_calendar_versions VALUES (NEW.user_id, lower(hex(randomblob(16))));
END;
CREATE TRIGGER IF NOT EXISTS account_version_audio_delete AFTER DELETE ON account_recordings
BEGIN
    INSERT OR REPLACE INTO account_calendar_versions VALUES (OLD.user_id, lower(hex(randomblob(16))));
END;
CREATE TRIGGER IF NOT EXISTS account_version_import_insert AFTER INSERT ON account_transcript_imports
BEGIN
    INSERT OR REPLACE INTO account_calendar_versions VALUES (NEW.user_id, lower(hex(randomblob(16))));
END;
CREATE TRIGGER IF NOT EXISTS account_version_import_remove AFTER UPDATE OF transcript ON account_transcript_imports
WHEN OLD.transcript IS NOT NEW.transcript
BEGIN
    INSERT OR REPLACE INTO account_calendar_versions VALUES (NEW.user_id, lower(hex(randomblob(16))));
END;
