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
