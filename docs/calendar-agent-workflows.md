# Calendar and local agent workflows

This development branch adds a fourth Calendar / Calendario tab to the existing Day, Week and Month popover. The native month grid uses the delivered October PDF's visual hierarchy: a Monday-first grid, restrained event cards, distinct recurrence shading and a selected-day detail list. Production dates come from connected calendars; reference-PDF proposals and the October 7/12 no-class annotations are isolated preview fixtures, not external calendar edits.

## Calendar events

Click a date and Add event. Choose an owner/writer calendar, title, start, exclusive end, IANA timezone and optional daily/weekly recurrence. Save is the only action that creates an event. The editor does not add attendees or invitations. Hidden calendars remain hidden. Read-only calendars cannot be selected for saving.

Initial Google connection retains calendar.readonly. Enable event writing explicitly requests calendar.events through the existing official PKCE/loopback OAuth flow, verifies the returned primary account and scope, then replaces its credential. EventKit uses the existing official full-access connection and verifies allowsContentModifications. Development tests and the preview do not accept these grants.

A durable local ledger stores the draft, destination and UUID before creating the event. Google uses the UUID as a legal client-supplied event ID; a 401 retries once, and a 409 reads and compares the existing event's authored fields. Duplicate clicks and restart retries reuse the ledger result. Ambiguous EventKit writes cannot retry automatically. A definite rejection can retry the same request. Account removal/deselection during a save cannot repopulate or enable the agenda cache.

Daily/weekly shading comes from actual Google parent RRULEs or EventKit recurrence rules. Missing metadata remains unknown. The app never synthesizes occurrences. Cancelled, declined, moved and detached instances retain provider semantics; originalStartTime remains the occurrence's dedup identity. No external recurrence is cancelled by the UI or by PDF context. Multi-day all-day events use an exclusive end and the source calendar timezone.

## Local agent briefings and commitments

A recording detail now offers Export evidence and Review briefing JSON. Export is a user-selected local text file containing the exact transcript hash and numbered utterances. It is not an upload. No report provider is called automatically by the default briefing pipeline; legacy explicit OpenClaw calls remain source-compatible for older operator workflows.

A local agent returns the existing halle.briefing.v1 JSON schema. The validator checks revision, unique item IDs, confidence bounds, actual excerpt text and timestamp bounds. Named owners and explicit dates must appear in validated excerpts; anonymous speaker labels cannot identify people. The review sheet shows claims and their evidence before Apply. Matching text cannot validate semantic interpretation, so human review remains required.

Apply stores a separate versioned JSON artifact and merges the managed briefing section. Cited utterances become Evidence uN anchors. Commitments are appended to the existing Actions marker block, which the existing actions/history/search UI already indexes. A repeated task ID does not reopen a completed checkbox. User notes and existing commitments remain in place. This branch does not move recordings, replace transcripts, regenerate historical reports or run a paid backlog.

## Five-minute preparation

A local 15-second timer checks actual upcoming calendar meetings (join link or non-self participants), within five minutes of their start. It uses saved meeting/project notes and commitments only. It respects notification and preparation toggles, quiet hours, cancellations, declines and rescheduling, and requires calendar/account freshness within 15 minutes. No model/provider call occurs on the timer. Durable acknowledgements avoid repeated popups; Snooze postpones by two minutes. Opening the meeting reuses its workspace inspector.

## On-demand weekly context

The Weekly review workspace route combines selected calendar scopes and existing Hall-E commitments with an explicitly reviewed local context import. It reports six domains: email, calendar, repositories, tasks, teaching and life. Missing domains are shown as unconnected. Freshness, authorization, exact coverage range, source scope and citations are mandatory; stale and partial data are labelled. Calendar coverage uses successful per-calendar window receipts rather than guessing from event counts. No recurring schedule is installed.

The handoff schema is halle.weekly-context.v1. JSON uses ISO8601 dates and sources with id, kind, label, scope, authorized, authorizationReference, collectedAt, coveredFrom, coveredTo, completeScope, items and optional error. Each item has id, title, detail, optional occurredAt and citation. The app accepts at most 5 MB and 5,000 items per source. Imported context stays in a private local file after explicit approval. The schema is not OAuth or a grant of connector permissions. Email and live repositories still require authorized external connectors/exporters; a local import does not establish complete personal coverage.

## Review and rollout

The checkout is isolated from the original dirty repository and installed application. Its baseline commit preserves the original working changes before these features. Do not replace /Applications/Hall-e.app without user approval. Live write grants, a real calendar save, signed release/migration/security gates and release installation remain separate action-time steps.

Use HALLE_DEBUG_CALENDAR_PREVIEW=1 with the development executable for a dedicated native window. Its launch and termination path bypasses AppState, recording recovery, database initialization, OAuth, notification permissions and all provider jobs. It uses mock events and a mock save callback. The preview has a separate bundle identity when packaged for native QA.

Focused verification covers CalendarAgentFeaturesTests, LocalBriefingSafetyTests and affected mapper/dedup/calendar/classifier/briefing/navigation suites. Follow docs/ci-policy.md; no hosted Actions or release was requested for this task.

API semantics were checked against [Google event insertion](https://developers.google.com/workspace/calendar/api/v3/reference/events/insert), [Google recurrence](https://developers.google.com/workspace/calendar/api/guides/recurringevents), and [Apple EventKit save](https://developer.apple.com/documentation/eventkit/ekeventstore/save(_:span:commit:)).
