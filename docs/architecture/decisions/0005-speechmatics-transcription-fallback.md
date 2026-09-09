> Historical migration document. Current public-release behavior is documented in [Current architecture](../CURRENT_ARCHITECTURE.md). Automatic cross-provider fallback now follows ADR 0006.

# ADR 0005: Explicit Speechmatics Transcription Fallback

Status: Accepted 2026-09-01 after independent review; implementation and live dry run pending
Date: 2026-09-01

## Context

Deepgram is Hall-E's automatic/default transcription provider, but it is currently not working for the operator. The exact failure is unknown. The operator requested Speechmatics as a fallback and supplied a key in chat. A credential disclosed in chat is treated as exposed and must be rotated before production use.

## Facts, assumptions, and unknowns

Verified: Hall-E is a low-volume, single-user macOS app with durable per-recording state and a provider-neutral `Transcript`. Speechmatics Batch accepts M4A through authenticated `POST /v2/jobs`; Melia 1 accepts `language: multi`, language hints, and speaker diarization; JSON-v2 returns timed words/punctuation and anonymous string speaker labels. Speechmatics retains Batch jobs for up to seven days. Public pricing observed 2026-09-01 lists Melia 1 at USD 0.129/hour without the optional account-level Model Training discount.

Assumed: Melia 1 is an acceptable emergency Spanish/English fallback, subject to a representative dry run. US1 is likely the appropriate region for a Chile-based operator, but the app requires explicit region selection rather than treating geography as contractual evidence.

Unknown: the Deepgram failure, Speechmatics key entitlement, live error payloads, latency/accuracy, account Model Training state, and contractual residency requirements.

## Minimum viable architecture

Keep Deepgram as `Automatic` and its explicit engine. Add `Speechmatics (fallback)` as an explicit engine selection. Do not automatically cross providers in this release.

The dependency-free Speechmatics REST adapter uploads the whole mixed M4A, persists a provider-labelled durable phase and returned job ID, resumes status/transcript retrieval after relaunch, stores raw JSON-v2 locally with mode `0600`, maps anonymous string speaker labels deterministically to Hall-E integer clusters, and promotes only timed, completely diarized output.

Before submission, persist phase `submitting`. After a successful create response, persist `providerJobID` before polling. A crash or lost response while `submitting` without a job ID is `ambiguous-submission` and requires operator action; it never silently re-uploads. A checkpoint with a job ID resumes and never creates a second job.

## Options considered

1. Retain Deepgram only or postpone: simplest, but leaves transcription blocked.
2. Automatic cross-provider failover: postponed because the triggering Deepgram failure and non-acceptance/billing semantics are unverified, and silent provider switching conflicts with Hall-E's explicit-engine policy.
3. Speechmatics SDK: rejected; three REST operations do not justify a dependency.
4. Explicit Speechmatics REST engine: selected as the smallest safe way to restore an alternate path.
5. Restore Whisper fallback: rejected; it conflicts with the approved migration and the operator requested Speechmatics.

## Decision

Implement option 4 using the operator-selected Speechmatics region (US1, EU1, or AU1), Melia 1, `language: multi`, `language_hints: ["es", "en"]`, `diarization: speaker`, and `prefer_current_speaker: true`.

Extend the cloud checkpoint additively with a typed provider, phase, and provider job ID. Old checkpoints decode as Deepgram/legacy. Launch reconciliation handles Speechmatics by phase: resume records with job IDs; convert stale `submitting` without an ID to ambiguous; never overwrite a Speechmatics checkpoint with a Deepgram checkpoint. User retry must preserve a resumable Speechmatics job ID and must not clear ambiguous submission evidence.

Generalize the existing spend ledger in place with backward-compatible optional/default provider fields. Each provider attempt has a provider-labelled fingerprint, rate/observation metadata, and reservation state. Explicit Speechmatics work creates only a Speechmatics reservation. Existing Deepgram entries decode as Deepgram. A future automatic-failover ADR must define definite-rejection settlement before reserving the next provider; that complexity is not needed here.

## Consent, security, and retention

Add separate Speechmatics audio consent in preferences. Speechmatics calls require that exact consent, a rotated Speechmatics Keychain secret, an explicitly selected region, and operator confirmation that the account-level Model Training program is off. Existing Deepgram consent never authorizes Speechmatics and is not reinterpreted.

The chat-disclosed key is not stored by implementation tooling and must be rotated before entry through Settings. Secrets never enter source, UserDefaults, logs, tests, or documentation.

This decision explicitly accepts Speechmatics' documented provider expiry of up to seven days for submitted audio/job data. Hall-E discloses that retention at opt-in and does not add a remote-deletion subsystem in this release. Consent revocation blocks new submission and transcript retrieval; already submitted data expires under the provider policy. Rollback must not claim immediate provider deletion.

## Cost and operations

Estimate Speechmatics at the observed USD 0.129/hour and count its provider-labelled reservations/completions/ambiguous submissions in the shared monthly cloud-transcription guard. Actual plan pricing remains authoritative.

Activation gates: rotated key, explicit region selection, Model Training confirmed off, Speechmatics-specific consent, and one representative dry run verifying authentication, M4A, Melia 1 entitlement, polling/resume, diarization completeness, response parsing, and raw-response persistence.

## Consequences

The operator maintains two provider accounts, credentials, consent records, API contracts, pricing baselines, and retention terms. Availability improves only when Speechmatics is explicitly selected; this release does not claim automatic recovery from the unidentified Deepgram outage. Output can differ in accuracy, punctuation, speaker clustering, and latency, while the normalized schema and raw response preserve auditability.

No SDK, database, queue, webhook, daemon, service, deployment unit, or general provider framework is added.

## Migration and rollback

Checkpoint, consent, and ledger changes are additive and backward-compatible. Existing recordings and Deepgram jobs remain Deepgram. Existing Deepgram-only consent stays valid only for Deepgram.

To activate: rotate/store a Speechmatics key, select a region, confirm Model Training off, grant Speechmatics consent, select the Speechmatics engine, and pass the dry run.

To roll back: switch the engine to Automatic/Deepgram and revoke Speechmatics consent. Completed provider-neutral transcripts and local raw responses remain readable. Removing the Keychain item does not delete remote jobs; any submitted data follows the disclosed provider expiry window.

## Reconsider when

- the current Deepgram failure is identified and its non-acceptance/billing semantics are verified;
- Speechmatics provides a documented idempotency key or job lookup that closes the create-response crash window;
- region, training, retention, price, accuracy, diarization, or latency fails the dry run; or
- a third provider or greater concurrency justifies a small shared orchestration layer.
