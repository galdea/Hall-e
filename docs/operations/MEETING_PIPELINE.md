# Hall-E meeting intelligence pipeline

Status: implemented locally on 2026-08-09; activation and migration remain gated.

## Runtime path

1. A completed recording is mixed once.
2. With explicit cloud-audio consent and a rotated Keychain key, Hall-E uploads the whole file to Deepgram Nova-3 multilingual with smart formatting, utterances, diarization v2, and Model Improvement Program opt-out.
3. Hall-E validates speaker-bearing words/utterances before atomically replacing the active transcript. Raw successful provider JSON and the prior transcript are retained.
4. With separate transcript-text consent, Hall-E invokes the dedicated tool-less `halle-reports` OpenClaw agent using a Gemini-only allowlist.
5. Every substantive report item must carry a valid utterance/time evidence anchor. Unknown owners are `Unassigned`; dates without evidence are rejected.
6. Hall-E writes `briefing.v1.json`, `briefing.md`, and `briefing.pdf`, then merges the Markdown into the managed Obsidian briefing section.

## Activation gate

The application fails closed until all of these are true:

- the exposed Deepgram key has been rotated and entered through Settings → Transcription;
- cloud-audio consent is recorded;
- cloud transcript-text consent is recorded;
- the `halle-reports` OpenClaw agent exists with no tools, no delivery, and primary model `github-copilot/gemini-3.1-pro`;
- a fixture transcription and a fixture report pass before real audio is selected.

Production OpenClaw configuration is intentionally not mutated by this implementation. Creating the agent remains a separately approved production-config action.

## Historical migration

Advanced Settings drives the gates in order: generate manifest, select and
transcribe A/B samples, accept the samples, run the backfill. The serial runner
requires:

- exactly bound manifest hash;
- 27 recordings / 67,950 seconds within 1%, or explicit variance acknowledgement;
- explicit projected-spend approval above USD 12;
- four accepted representative A/B sessions and sample reports;
- no active recording;
- active consent and Keychain key.

It checkpoints after every recording and writes a reconciliation document with
completed, skipped, ambiguous, and failed counts plus request IDs and artifact
hashes.

### A/B samples

`DeepgramABSampleRunner` selects one recording per required category using local
proxies only — lowest characters-per-minute in the existing Whisper transcript
for difficult attribution, most English function words inside a Spanish
transcript for code-switching, most calendar attendees for noisy multi-speaker,
and highest characters-per-minute among small meetings for clean Spanish. The
proxy is recorded with each selection because it is an inference from the prior
output, not a measured property of the audio, and it can be overridden.

Samples are written to `Backfill/Samples/<category> - <slug>/` as
`deepgram-transcript.json` plus a readable `comparison.md`. Nothing in that
folder is an active artifact: the sample path never writes `transcript.json`,
never mutates a transcription job, and never rewrites an Obsidian note, so a
rejected sample costs only its request.

### Paying once

Successful raw responses are also written to `Backfill/RawResponses/`, keyed by
audio SHA-256 plus a digest of the request options. Both the sample runner and
the backfill consult that cache before authorizing spend, so a recording used as
an A/B sample is not billed again during the full run, and re-normalizing after a
schema change is free. Transcripts normalized from cache carry
`providerMetadata.reusedCachedResponse`. Reuse sits *after* the consent and key
guards: revoking consent stops Hall-E producing new Deepgram transcripts, not
merely new uploads.

### Manifest hash

`manifestHash` encodes with sorted keys and ISO-8601 dates. A default
`JSONEncoder` does not order keys and produced roughly 94 distinct hashes for 500
encodings of one unchanged manifest, which made the authorization binding reject
untampered manifests as "changed after approval". The canonical encoding is
covered by a regression test.

## Credit and spend alerting

Two independent things stop Deepgram transcription for a money reason, and both
raise a macOS notification:

- the Deepgram account running out of credit, reported as HTTP 402 or an
  insufficient-credit error code on a transcription request; and
- Hall-E's own monthly spend guard being reached, which blocks the upload locally
  before any request is made.

`DeepgramCreditMonitor` owns the alert. It is throttled to one notification per
reason per 24 hours, so a batch of failed recordings is not a batch of alerts,
and it fires only on money failures — a 500, a plain 403, or a bad request must
never claim the account is empty.

Detection is deliberately reactive-first. Reading the balance requires the
`billing:read` scope, which a transcription-only key does not have; with the
current key `GET /v1/projects/{id}/balances` answers `INSUFFICIENT_PERMISSIONS`.
`DeepgramCreditWatchdog` still checks on launch and daily, so if a key with that
scope is ever issued the low-balance warning (default under USD 5) starts working
with no further change. Until then the guaranteed notice is the failed request.

Verify delivery with `HALLE_DEEPGRAM_OP=test-alert`, and check scope with
`HALLE_DEEPGRAM_OP=balance`.

Failed recordings are never lost: the audio and the prior transcript are kept and
the job stays retryable, so restoring credit and retrying is sufficient.

## Whisper removal — completed 2026-08-18

Whisper is gone. Removed under ADR 0004 after reconciliation was accepted:

- WhisperKit package dependency, engine, provider, model manager, CLI provider,
  resolver branches, settings UI, and tests deleted; `Package.resolved` now
  resolves GRDB only.
- The 600 MB app-owned model directory (`Application Support/Hall-e/Models`) was
  deleted after its exact contents were validated.
- Homebrew `openai-whisper` (20250625_3) and `whisper-cpp` (1.9.1) uninstalled.
  Both were installed on request and `brew uses --installed` reported no
  dependents.

Rollback artifact, recorded before removal: tag `pre-whisper-removal`, commit
`bc46d4c`, and `Backfill/rollback/Hall-e-pre-whisper-removal.tar.gz`
(sha256 `e8d0368439…`) with `brew-inventory-pre-removal.json`.

**Deviation to note:** `brew uninstall` also removed the dependencies `isl`,
`libmpc`, `mpfr`, `ggml`, and `libomp`, which ADR 0004 did not sanction — it
forbids `brew autoremove` and expects unrelated dependencies to remain. Checked
afterwards: no formula depends on them (`gcc` and `llama.cpp` are not installed),
`brew missing` reports only a pre-existing stale `gcloud-cli: python@3.12`
receipt, and `gcloud` and `ffmpeg` both verified working. Restore with
`brew install isl libmpc mpfr ggml libomp` if anything later needs them.

There is no local transcription engine left apart from Apple Speech, which is
explicit-only. `auto` now means Deepgram, and no launch path can download a model.
