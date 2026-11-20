-- Deliberately separate from the workspace Durable Object and native meeting libraries.
CREATE TABLE IF NOT EXISTS account_meetings (
    user_id TEXT NOT NULL,
    id TEXT NOT NULL,
    title TEXT NOT NULL,
    start_at TEXT NOT NULL,
    end_at TEXT NOT NULL,
    revision INTEGER NOT NULL CHECK (revision > 0),
    deleted INTEGER NOT NULL CHECK (deleted IN (0, 1)),
    last_mutation TEXT NOT NULL,
    PRIMARY KEY (user_id, id)
);

-- A durable receipt allows a device to replay an offline queue even after later edits.
CREATE TABLE IF NOT EXISTS account_meeting_mutations (
    user_id TEXT NOT NULL,
    mutation_id TEXT NOT NULL,
    meeting_id TEXT NOT NULL,
    fingerprint TEXT NOT NULL,
    PRIMARY KEY (user_id, mutation_id)
);
