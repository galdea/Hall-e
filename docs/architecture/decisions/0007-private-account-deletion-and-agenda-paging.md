# 0007 — Private account deletion and agenda paging

Date: 2026-11-21. Status: **Accepted 2026-11-22 by the owner** (deletion option B; agenda option B, extended to store large transcripts separately). Independent cross-provider review of the implementation is still due.

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

## Implementation contract (2026-11-22)

All paths are relative to `/account/v1`. Old clients keep working: nothing changes for a client that does not opt in.

**Capabilities.** `GET auth/session` adds `features: {accountDeletion: boolean, lazyTranscripts: true}`. `accountDeletion` is true only when the Worker variable `ACCOUNT_DELETION_ENABLED` is exactly `yes`. Clients show "Delete account…" only when it is true.

**Account deletion.** `POST account/delete` with an authenticated session and body `{"confirmation": "DELETE"}`.
- `202 {"status": "deleting"}`: all of the user's rows are removed in one D1 batch, every session and identity of the user is revoked, and the user's audio and stored transcripts are queued for R2 disposal by a table that does not depend on the deleted rows. Disposal starts at once (`waitUntil`) and the cron retries it.
- `403 {"error": "deletion_disabled"}` when the flag is off; `400 {"error": "confirmation_required"}` when the body is wrong.
- The same session afterwards gets `401`. A retry after a failure before commit repeats the batch safely.
- Provider-side copies are disclosed, not deleted. An audit log line carries only a hashed user reference, never an email.
- Clients: typed confirmation, then on 202 they wipe that account's local cache and stored session (Keychain or Keystore) and return to the sign-in screen. Local recordings and the personal library stay.

**Lazy transcripts.** `GET meetings?transcripts=lazy` (combinable with `since=`). Every recording, including `local-import` copies, then carries `transcript: null`, `transcriptAvailable: boolean` and `transcriptBytes: number|null`.
- `GET meetings/:id/recordings/:rid/transcript` returns `200 text/plain; charset=utf-8` with the text, `404 {"error": "not_found"}` when there is none. The same path serves `local-import` copies by their recording ID.
- Without `transcripts=lazy`, responses are unchanged, except that a transcript stored separately is sent as `transcript: null, transcriptStoredSeparately: true`.

**Large transcripts.** A provider transcript whose formatted text exceeds 512 KiB, up to 8 MiB, is stored in R2 under the recording's prefix and served by the transcript endpoint. The recording completes normally. Above 8 MiB, or if the provider JSON exceeds 12 MiB, the existing `review` path and owner discard still apply.
