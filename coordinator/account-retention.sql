-- Idempotent data backfill, applied after account-meetings and account-projects. Safe to re-run.
-- Deletes now write a neutral instant and drop labels no meeting uses. This clears rows written earlier.
UPDATE account_meetings SET start_at = '1970-01-01T00:00:00.000Z', end_at = '1970-01-01T00:00:00.000Z'
WHERE deleted = 1 AND (start_at <> '1970-01-01T00:00:00.000Z' OR end_at <> '1970-01-01T00:00:00.000Z');

DELETE FROM account_projects WHERE NOT EXISTS (
    SELECT 1 FROM account_meeting_projects link
    WHERE link.user_id = account_projects.user_id AND link.project_id = account_projects.id
);
