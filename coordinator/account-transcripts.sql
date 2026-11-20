-- Copies of completed transcripts imported explicitly by the user. Local originals are independent.
CREATE TABLE IF NOT EXISTS account_transcript_imports (
    user_id TEXT NOT NULL,
    id TEXT NOT NULL,
    meeting_id TEXT NOT NULL,
    transcript TEXT CHECK (length(CAST(transcript AS BLOB)) <= 524288),
    PRIMARY KEY (user_id, id),
    FOREIGN KEY (user_id, meeting_id) REFERENCES account_meetings (user_id, id) ON DELETE CASCADE
);

-- A tombstone prevents an old retry from restoring an explicitly removed copy.
-- Deleting the parent meeting blocks future imports and removes both text and receipts.
CREATE TRIGGER IF NOT EXISTS account_meeting_purge_imports
AFTER UPDATE OF deleted ON account_meetings
WHEN NEW.deleted = 1 AND OLD.deleted = 0
BEGIN
    DELETE FROM account_transcript_imports
      WHERE user_id = NEW.user_id AND meeting_id = NEW.id;
END;
