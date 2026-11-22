# 0007 — Private account deletion and agenda paging

Date: 2026-11-21. Status: **Proposed — needs owner approval and an independent review before implementation.**

## Context

The private account service (`coordinator/src/account-*.mjs`, Mac `Sources/HallE/Agenda`, Android `AccountCalendar*.kt`) went to `main` on 2026-11-20 and runs only on an isolated staging service with two synthetic identities. Two gaps must be settled before real accounts use it:

1. **No full account deletion.** Users can delete meetings, revoke sessions and unlink identities. Nothing removes the account itself with all its rows, audio and transcripts. The privacy texts already disclose this.
2. **The agenda is sent whole.** `GET /meetings` returns every meeting, including tombstones and up to 512 KiB of transcript per recording, whenever the calendar version changes. Clients pull it after every accepted change.

Verified facts: tables are keyed by `user_id`. Audio is in a private R2 bucket under per-recording prefixes. Recording disposal already exists (`disposeOne`, cron plus prompt trigger on meeting delete). Provider jobs (Deepgram, Speechmatics) keep their own copies under each provider's retention. Unknown: expected library size per account; whether operators need a recovery window; legal retention duties for a Chilean operator.

## Options — account deletion

| Option | Summary | Cost | Risk |
| --- | --- | --- | --- |
| A. Do nothing now | Keep disclosure; staging only | None | Blocks opening the service to real users |
| B. Immediate hard delete | One authenticated request deletes every row for the user, revokes sessions, queues all R2 prefixes for disposal | Small: one endpoint, one batch, reuse `disposeOne` | No undo; partial failure must stay retryable |
| C. Soft delete + grace period | Mark account closed, block sign-in, purge after N days by cron | Medium: new state, cron job, restore path | More code paths; data kept longer than the user expects |

**Recommendation: B**, with a typed confirmation in both clients. Make the batch idempotent: a second request after partial failure finishes the job. R2 purge is asynchronous and retried by the cron. Provider-side deletion is attempted for stored job IDs where the provider supports it, otherwise disclosed. Clients wipe their per-account cache and Keychain/Keystore entries and keep local recordings. Revisit C if the owner wants a recovery window.

## Options — agenda size

| Option | Summary | Cost | Risk |
| --- | --- | --- | --- |
| A. Keep whole-agenda pulls | Measure first | None | Slow sync and high transfer for large libraries |
| B. Lazy transcripts | Agenda carries recording metadata only; transcript fetched per recording on open | Small–medium: new GET, client fetch-on-open and cache | Offline view needs the transcript cached first |
| C. Delta sync | `GET /meetings?since=<version>` returns only rows changed after a server sequence | Medium: per-row sequence column, tombstone retention rule, client merge | Merge bugs; tombstone expiry must outlive the longest offline client |

**Recommendation: measure (HAL-10), then B.** B removes the dominant payload (transcripts) with little new state. Adopt C only if metadata alone becomes large. Both are additive: old clients keep working if the server keeps sending transcripts when asked by an old client version.

## Consequences, security and operations

- B (deletion) adds one destructive endpoint. It requires a fresh session plus the confirmation token, rate limiting and an audit line without personal data.
- Lazy transcripts reduce data held on devices that only browse the calendar.
- No new services or bindings; reuses D1, R2 and the existing cron.

## Rollback and reconsideration

Deletion cannot be rolled back once executed, so it ships behind a server flag, off by default, enabled only after staging tests with synthetic accounts. Lazy transcripts roll back by restoring inline transcripts on the server. Reconsider if account sizes exceed the measured budget, a regulator requires a retention window, or shared organization projects (HAL-2/HAL-3) change data ownership.
