-- Opt-in account labels. The Mac's aliases, client contacts and source folders stay local.
CREATE TABLE IF NOT EXISTS account_projects (
    user_id TEXT NOT NULL,
    id TEXT NOT NULL,
    name TEXT NOT NULL,
    PRIMARY KEY (user_id, id)
);
CREATE TABLE IF NOT EXISTS account_meeting_projects (
    user_id TEXT NOT NULL,
    meeting_id TEXT NOT NULL,
    project_id TEXT NOT NULL,
    PRIMARY KEY (user_id, meeting_id),
    FOREIGN KEY (user_id, project_id) REFERENCES account_projects(user_id, id),
    FOREIGN KEY (user_id, meeting_id) REFERENCES account_meetings(user_id, id)
);
