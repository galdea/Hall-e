> Historical migration document. Current public-release behavior is documented in [Current architecture](CURRENT_ARCHITECTURE.md). Automatic cross-provider fallback now follows ADR 0006.

# Hall-E Project Profile

Status: Architecture verified through 2026-09-01; production activation remains gated

## Verified facts

- Existing single-user macOS 14+ menu-bar/workspace application written in Swift and AppKit/SwiftUI.
- Swift Package Manager application with GRDB persistence and local session folders under Application Support.
- Primary workflows: calendar sync, meeting/call recording, durable transcription, Obsidian notes, project classification, and AI-assisted project context.
- Recordings, session state, transcripts, and retry checkpoints are locally persisted. The current product is local-first.
- The staged implementation adds Deepgram Nova-3 multilingual while retaining Whisper CLI, WhisperKit, and explicit Apple Speech until migration acceptance. Automatic selection uses Deepgram only when consent and a rotated Keychain credential are ready.
- Deepgram remains the automatic/default cloud transcription provider. Speechmatics Batch Melia 1 is approved as an explicit fallback engine the operator can select while Deepgram is unavailable, subject to an independently stored Keychain credential and provider-specific consent.
- Live historical inventory: 27 sessions, 27 actual transcription input M4As, 67,950 seconds (18.88 hours); all 27 active transcripts report `whisper-large-v3-turbo-cli`.
- The new durable briefing pipeline invokes a dedicated OpenClaw/Gemini agent, validates evidence-backed canonical JSON, and produces Markdown/PDF/Obsidian artifacts independently of transcription success.
- The configured OpenClaw model catalog exposes `github-copilot/gemini-3.1-pro`, `github-copilot/gemini-3-flash`, and `github-copilot/gemini-2.5-pro`.
- Projects can persist a validated, self-contained visual briefing profile copied from a repository or use the built-in profile.
- The working tree is extensively dirty and all existing changes are user-owned.

## Approved requirements

- Replace Whisper with Deepgram for historical and future recordings.
- Upload historical and future audio to Deepgram with a separate explicit cloud-audio consent and Model Improvement Program opt-out.
- Use Deepgram speaker diarization; preserve anonymous speaker IDs and identify people only from evidence.
- Re-transcribe and regenerate corporate briefings for all 27 historical sessions.
- After each future meeting ends: transcribe, analyze, produce Markdown and a one-page PDF (two pages only when necessary), update Obsidian, and surface status/failure.
- Briefings prioritize general objectives, individual tasks, owners, dates, decisions, risks, and next milestones.
- Uncertain ownership is `Unassigned`; owners and dates are never invented.
- Run report analysis through OpenClaw using Gemini models, not the full federation workflow.
- Import a small project-specific Hall-E design profile from each project repository and persist a self-contained copy so repository deletion does not break rendering.
- Retain raw Deepgram responses, prior transcripts, canonical briefing JSON, Markdown, and PDF until manual deletion.
- Remove Hall-E Whisper code, dependencies, app-owned models, and the global Homebrew `openai-whisper` and `whisper-cpp` installations after the migration gate passes.
- Keep Deepgram as the automatic/default engine and expose Speechmatics as an explicit fallback selection. Postpone automatic failover until the current Deepgram failure and its accepted/billable error semantics are verified.

## Classification

- Purpose/users: Gabriel's private meeting and project operating assistant; single primary user.
- Application type: application-first native desktop app; no web rendering boundary except local HTML used for deterministic PDF output.
- Authentication/roles/tenants: local single-user application; external provider credentials in macOS Keychain; no multi-tenancy.
- Data ownership: local audio and canonical artifacts owned by Gabriel; cloud processors receive scoped copies for transcription/analysis.
- Read/write/concurrency: low concurrency, mostly sequential writes; recording must never overlap heavy backfill work.
- Transactions: atomic per-session artifact promotion; no cross-session transaction required.
- Offline: recording and local artifact access remain available; transcription/report generation become network-dependent after final Whisper removal.
- Privacy/security: third-party meeting audio and transcript text are sensitive; separate audio/text consent, provider-specific audio consent, local subprocess-only OpenClaw invocation, least-privilege agent, and secret redaction are required. Gabriel is responsible for ensuring recording and cloud processing are lawful and that participants receive any notice or consent the meeting context requires; Hall-E surfaces that responsibility at opt-in.
- Integrations: Deepgram prerecorded REST (primary), Speechmatics Batch REST (fallback), local OpenClaw Gateway/CLI, GitHub Copilot Gemini model through OpenClaw, Obsidian vault, Google Calendar.
- Deployment: locally signed macOS app installed under `/Applications`.
- Expected scale: low-volume single-user workload; 27 historical sessions and future meeting-by-meeting processing.
- Maintenance capacity: one developer/operator; architecture must remain single-process and inspectable.
- Project lifespan: ongoing personal work system.
- Likely twelve-month changes: additional projects/design profiles, more recordings, stronger speaker attribution, report template iteration, possible provider/model changes.

## Assumptions

- Nova-3 multilingual is appropriate for Spanish/English code-switching, subject to the A/B gate.
- Automatically generated PDF plus Markdown is the desired final artifact pair.
- `github-copilot/gemini-3.1-pro` remains available to OpenClaw; the model is an operational configuration, not a permanent content contract.
- Project repositories are available during initial design import but may later be deleted.
- US1 is the suggested Speechmatics region for the Chile-based operator, but the operator must explicitly select/confirm US1, EU1, or AU1 before consent is granted.

## Unknowns and reconsideration triggers

- Exact Deepgram accuracy relative to Whisper on this corpus remains unmeasured.
- Named voice recognition is not included; future biometric voice enrollment requires a separate privacy and security decision.
- Deepgram account credit/concurrency limits and first-invoice pricing must be confirmed during dry run.
- Speechmatics fallback accuracy, latency, account-level Model Training setting, US1 entitlement, and live error payloads remain unverified until a rotated key and representative dry run are available.
- The exact Deepgram failure currently affecting the operator is unknown; fallback eligibility remains deliberately narrower than “any error.”
- Reconsider if cloud terms, model pricing, accuracy, OpenClaw model availability, or privacy obligations materially change.
