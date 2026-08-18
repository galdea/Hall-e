# ADR 0001: Deepgram Cloud Transcription

Status: Accepted and implemented locally — user-approved 2026-08-09; activation remains gated by ADR 0004
Date: 2026-08-09

## Context

Hall-E currently transcribes locally with Whisper CLI/WhisperKit or explicit Apple Speech. Gabriel approved moving historical and future recordings to Deepgram and requested speaker separation.

## Decision

Add an explicit Deepgram engine using prerecorded HTTPS `POST /v1/listen`, one whole-file request per actual input:

- `model=nova-3`
- `language=multi`
- `smart_format=true`
- `utterances=true`
- `diarize_model=v2`
- `mip_opt_out=true`
- optional repeated, encoded `keyterm=` values after the A/B gate

Do not send deprecated `diarize=true`. The `diarize_model=v2` request shape and Nova-3 multilingual keyterm support were checked against Deepgram's live documentation on 2026-08-09; the implementation dry run must still exercise both before enabling them. Keyterms remain off if the provider rejects their use with `language=multi`. Do not use `AudioChunker`; cross-request speaker numbers are not stable. Stream the M4A from disk with `URLSession`.

Store the replacement Deepgram key in macOS Keychain under a transcription-specific account. The key disclosed in chat is considered exposed and must be rotated before production use.

Add `allowCloudAudioTranscription`, default off, versioned and timestamped. It is independent from cloud transcript-text processing. Revocation blocks new/resumed uploads without deleting local audio.

## Speaker contract

Persist word/utterance timestamps, `speaker`, speaker confidence, and provider request metadata. Deepgram separates speakers as anonymous numeric labels; it does not establish legal identity.

Hall-E may attach a name only when supported by explicit spoken self-identification or corroborated meeting/person context. Corroboration must be a persisted evidence record such as an explicit attendee-to-speaker statement or independently confirmed speaker mapping; an attendee list or two-person inference alone is insufficient. Render inferred names as inferences and preserve the evidence type. Otherwise render `Speaker N`. Biometric voice enrollment/voiceprints are excluded and require a future ADR.

## Options considered

- Keep Whisper: rejected because it does not meet the approved migration.
- Streaming Deepgram: rejected; Hall-E processes completed files and needs no live captions.
- Deepgram SDK: rejected; one REST endpoint does not justify another dependency.
- Chunked uploads: rejected because they break stable diarization and can rebill overlap.

## Consequences

- Raw third-party audio leaves the Mac under explicit consent.
- Transcription depends on network, provider credit, and a valid key after final Whisper removal.
- The pricing baseline observed 2026-08-09 is USD 0.0058/minute for Nova-3 multilingual plus USD 0.0020/minute for diarization: USD 0.0078/minute before keyterms, tax, discounts, or plan variance. The historical estimate is therefore about USD 8.84 for 1,132.5 minutes.
- Persist raw successful responses locally with mode `0600` so normalization/reporting can be repeated without a new paid transcription.

## Operations and failure policy

- Locally idempotent request fingerprint: session UUID, source SHA-256, bytes, duration, provider/model/options/keyterms/schema.
- States distinguish queued/uploading/awaiting/validating/completed, retryable failure, permanent/action-required failure, ambiguous billed state, consent-blocked, and cancelled.
- Retry 408/429/5xx/transport with bounded exponential backoff and jitter; honor `Retry-After`.
- 400/401/402/403/413 and invalid schema require action and are never included in blind retry-all.
- An ambiguous lost response is surfaced for manual retry because the client cannot guarantee exactly-once billing.
- A non-empty transcript response must contain speaker fields on its normalized words/utterances. Missing diarization fails validation and cannot replace the active transcript.
- Before every upload, estimate cost from the current configured rate. Default recurring guard: USD 25 per calendar month across completed, in-flight, and manually retried work. Reaching the guard pauses new uploads and surfaces action required; only Gabriel can approve a higher limit. Never silently downgrade the model or omit diarization to fit the guard.
- Persist the pricing baseline, observation date, estimate, actual provider metadata when available, and user-approved guard override in the job/reconciliation record.

## Rollback

Before promotion, keep the prior transcript and prior Obsidian marker content immutable. During migration, switching back to local Whisper remains possible. After final uninstall, rollback requires restoring the tagged, archived pre-removal app build and reinstalling recorded Homebrew packages on the best-effort terms in ADR 0004.

## Reconsider when

Accuracy fails the approved A/B gate; invoices exceed the spend ceiling; provider terms/retention change; or offline transcription becomes required.
