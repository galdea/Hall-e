> Historical migration document. Current public-release behavior is documented in [Current architecture](CURRENT_ARCHITECTURE.md). Automatic cross-provider fallback now follows ADR 0006.

# Stack Scorecard

Status: Accepted and implemented locally 2026-08-09; activation/removal remain gated by ADR 0004

| Factor | Keep Whisper | Deepgram + permanent Whisper fallback | Deepgram + staged migration, then full removal | Decision |
|---|---|---|---|---|
| Product fit | Does not meet request | Meets transcription goal but not removal request | Meets all approved requirements | Staged, then remove |
| Simplicity | Existing complexity | Four engines indefinitely | One cloud engine after acceptance | Full removal |
| Maintainability | Known local stack | Highest long-term branching | Small REST adapter and explicit states | Deepgram |
| Cost | No marginal transcription cost | Cloud cost plus local footprint | Cloud cost; historical estimate about USD 8.84 before keyterms/tax | Spend guard required |
| Privacy | Best | Cloud boundary plus offline option | Cloud-dependent; explicit consent required | Approved with separate consent |
| Security | No new key | New key plus fallback | New key; Keychain only | Rotate disclosed key |
| Performance | Slow local CPU transcription | Cloud primary, local fallback | Cloud primary only | A/B and runtime gate |
| Operations | Offline-capable | Most resilient, most moving parts | Network/key/vendor dependency | Explicit action-required states |
| Portability | High | High | Moderate provider lock-in | Preserve raw audio and normalized schema |
| Migration difficulty | None | Low | Moderate because uninstall is destructive | Removal last |
| Rollback | N/A | Runtime switch | Reinstall known-good build and packages | Backups + standalone uninstall |
| Reversibility | High | Highest | Acceptable only with preserved artifacts and installer record | Gate required |

## Complexity challenge

- No new database, ORM, queue, cache, daemon, service, or deployment unit.
- No Deepgram SDK; use `URLSession`.
- No streaming transcription; completed recordings use prerecorded REST.
- No arbitrary remote templates, JavaScript, or CSS.
- PDF/report/design work is a separate landing phase from provider migration even though both belong to one approved program.
- Speaker diarization is enabled only after the transcript schema can preserve it.

## Provider availability decision (2026-09-01)

| Factor | Deepgram only | Automatic REST failover | Explicit Speechmatics REST engine | Postpone fallback |
|---|---|---|---|---|
| Product fit | Current outage can stop transcription | May restore eligible failures, but trigger is unverified | Restores an operator-selected alternate path | Does not meet the request |
| Simplicity | Fewest components | Adds error classification and cross-provider orchestration | Adds one adapter, engine case, consent, and credential | No implementation work |
| Maintainability | One API contract | Two contracts plus failover policy | Two narrow REST contracts | Outage remains operational work |
| Cost | Existing Nova-3 pricing | Requires multi-attempt settlement | One provider-labelled reservation per selected attempt | Deferred cost, no resilience |
| Privacy/security | One audio processor | Second processor and key | Second processor and key, explicitly consent-gated | No new disclosure boundary |
| Performance | No fallback availability | Batch latency | Batch latency; diarization may add 10–50% processing time | No fallback availability |
| Operations | Current single point of failure | Hidden switching plus two accounts | Explicit selection, provider-labelled durable job, local raw response | Manual retry until Deepgram recovers |
| Portability/lock-in | Deepgram-specific request, normalized output | Two providers but SDK coupling | Two providers behind normalized transcript output | Deepgram-only |
| Migration/rollback | None | Remove SDK and adapter | Disable/remove fallback key; Deepgram path unchanged | None |
| Reversibility | High | Moderate | High | High |

Decision: keep Deepgram automatic/default and add the minimal Speechmatics Batch REST adapter as an explicit fallback engine. Automatic failover is postponed until the current Deepgram fault and non-acceptance/billing semantics are verified.

Additional complexity remains intentionally excluded: no SDK, queue, webhook receiver, database, service, daemon, streaming API, automatic failover classifier, or provider-wide framework. The existing per-recording checkpoint gains only typed provider/phase/job-ID fields. A stale submission with no returned job ID fails closed as ambiguous rather than uploading again.
