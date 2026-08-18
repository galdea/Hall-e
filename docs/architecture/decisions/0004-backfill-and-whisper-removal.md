# ADR 0004: Historical Backfill and Final Whisper Removal

Status: Executed 2026-08-18 — backfill reconciled 28/28 (USD 9.51) and Whisper fully removed. See `docs/operations/MEETING_PIPELINE.md` for the removal record, the rollback artifact, and one deviation: `brew uninstall` also took the dependencies isl, libmpc, mpfr, ggml, and libomp, which this ADR did not sanction; no installed formula depends on them and gcloud/ffmpeg were verified working.
Date: 2026-08-09

## Context

The migration must replace 27 active transcripts and ultimately remove application and machine-level Whisper components without destroying the only usable rollback state in a heavily modified working tree.

## Decision

Treat migration as staged and reversible until reconciliation is accepted, then fully remove Whisper as Gabriel requested.

## Migration gates

1. Rotate/store the replacement Deepgram key; record explicit historical cloud-audio consent.
2. Generate a zero-network manifest for the 27 inputs with hashes, bytes, durations, project, current transcript hash/source, output IDs, and estimated cost.
3. Snapshot current transcript JSON and the Obsidian transcript/brief marker interiors without deleting or replacing active artifacts.
4. A/B representative clean Spanish, Spanish/English code-switching, noisy/far-field multi-speaker audio, and difficult attribution.
5. Acceptance: no critical omissions, names/numbers/dates reviewed, diarization usable, every report evidence anchor valid, zero invented owners/dates, retry/crash recovery passes, and Gabriel approves sample reports. Numeric WER is recorded where a corrected reference exists but is not the only gate.
6. Process historical inputs serially, never while recording; require manual confirmation if projected spend exceeds USD 12 or the manifest differs from 27 inputs/1,132.5 minutes by more than one percent.
7. Atomically promote each validated transcript, then run the independent briefing job and render artifacts.
8. Produce reconciliation: expected/completed/skipped/ambiguous/failed, actual provider metadata/cost where available, hashes, and request IDs.
9. Gabriel accepts reconciliation and sample output.
10. Create a known-good pre-removal rollback artifact: commit and tag the exact accepted state, archive the built/signed `.app`, and record the commit, tag, app hash/path, and package inventory in the reconciliation manifest.
11. Remove Whisper in a final standalone operation.

## Full removal scope

- Remove WhisperKit package dependencies and resolution entries.
- Remove WhisperKit engine/provider/model manager/settings/tests and Whisper CLI provider/resolver branches.
- Delete Hall-E app-owned Whisper model directories only after their exact paths are validated.
- The migration operator—not the Hall-E app—performs global package removal only after Gabriel's explicit final confirmation; it is never unattended application behavior.
- Record `brew info --json=v2` state and run `brew uses --installed` for both formulas. Abort removal if another installed package depends on either formula until Gabriel reviews that dependency.
- Uninstall only the explicitly installed global Homebrew `openai-whisper` and `whisper-cpp` formulas.
- Do not run broad `brew autoremove` as part of this migration; unrelated dependencies remain untouched unless separately approved.
- Update documentation/privacy/settings and verify no launch path attempts a model download.

## Artifact retention

Raw audio, prior transcripts, raw successful Deepgram responses, canonical briefing JSON, Markdown, PDF, and reconciliation manifests remain until explicit manual deletion. Deletion uses existing guarded recording-folder boundaries and enumerates exactly what will be removed. Transcript-bearing OpenClaw sessions and provider-retained copies are separately enumerated limitations; local deletion does not claim immediate provider-side erasure.

## Rollback

Before removal: switch back to the local engine and restore preserved active-artifact pointers. After removal: restore the tagged build, reinstall the recorded Homebrew formula versions or current compatible versions, and restore prior transcript pointers. Exact historical Homebrew versions may no longer be obtainable, so package restoration is explicitly best-effort; the archived app and local artifacts are the durable rollback assets. No automatic destructive rollback.

## Options considered

- Keep Whisper indefinitely as fallback: rejected because Gabriel explicitly approved full removal and it preserves unnecessary code/model/package surface.
- Remove Whisper before backfill: rejected because it destroys the easiest rollback before acceptance.
- Staged migration followed by a separately confirmed removal: selected because it preserves reversibility through reconciliation.

## Reconsider when

The A/B gate fails, reconciliation is incomplete, an ambiguous paid request remains unresolved, OpenClaw/Gemini reports fail quality review, or offline transcription is required.
