# ADR 0002: OpenClaw Gemini Meeting Briefings

Status: Accepted and implemented locally — user-approved 2026-08-09; production agent creation remains separately gated
Date: 2026-08-09

## Context

Gabriel approved using OpenClaw with Gemini models for automatic meeting analysis, but not the full system federation workflow. Existing direct Gemini enrichment is not durable and silently drops failures.

## Decision

Create a dedicated OpenClaw agent ID `halle-reports` with:

- primary model `github-copilot/gemini-3.1-pro` (currently available in the local OpenClaw model catalog);
- no messaging delivery;
- no delegation, gateway, browser, messaging, filesystem, shell, or external-action tools;
- a narrow system prompt that accepts transcript/context and returns only the versioned briefing JSON contract;
- isolated per-job sessions and bounded session cleanup.

Hall-E writes the prompt to a `0600` temporary file, invokes the local CLI through `Process`, and captures JSON output:

`openclaw agent --agent halle-reports --message-file <path> --model github-copilot/gemini-3.1-pro --json --session-key <derived-job-key> --timeout <bounded>`

The temporary prompt is removed after capture. Canonical results live in the recording folder. OpenClaw session copies are operational artifacts, not canonical records, and may be pruned after 30 days with agent-scoped session maintenance.

Every briefing job is gated by the existing, independently revocable cloud transcript-text consent. The consent record names OpenClaw plus the selected GitHub Copilot/Gemini processor, includes the policy/retention baseline and observation date presented at opt-in, and is re-confirmed when the processor or material terms change. Revocation blocks new and resumed briefing jobs without changing completed transcripts or deleting canonical local artifacts.

Do not enable the Gateway OpenAI Chat Completions endpoint for Hall-E. Its bearer token is a full operator credential and is too broad for this integration. Do not use `/hooks/agent`: it is asynchronous and does not return the structured result directly to Hall-E.

## Briefing contract

Return structured JSON containing: headline, ranked general objectives, individually owned tasks, explicit dates, decisions, risks/blockers, open questions, next milestones, confidence, transcript hash, prompt/model provenance, and evidence anchors.

Every substantive item includes utterance/time evidence. Tasks use `knownPerson`, `explicitName`, or `unassigned`. Anonymous speaker numbers never become names without corroborating evidence. Dates are `null` unless explicitly stated or safely resolved from an explicit relative date and meeting date.

## Options considered

- Existing direct Gemini API: simpler but violates the approved OpenClaw execution requirement.
- Full system federation: rejected by Gabriel for routine automatic reports.
- OpenClaw HTTP Chat Completions: rejected because it exposes full operator access.
- OpenClaw webhook: rejected because accepted runs are asynchronous and do not synchronously return the report JSON.
- Local OpenClaw CLI with dedicated agent: selected; it uses the supported Gateway agent path, avoids gateway credentials in Hall-E, and returns machine-readable output.

## Consequences

- OpenClaw and the selected Gemini model must be available for report generation, but transcript completion remains independent.
- Briefing generation gets its own durable job and retry state; it never changes a completed transcript to failed.
- Model ID, prompt version, transcript hash, and output schema are persisted for auditability.
- Model availability can change; the agent/model selection is configurable behind an explicit allowlist of Gemini-only models.
- Analysis cost and quota follow the configured GitHub Copilot/OpenClaw entitlement. Rate limits or exhausted quota pause the briefing job and surface action required; they never trigger a non-Gemini or direct-provider fallback.
- Transcript-bearing OpenClaw sessions and provider-side copies are outside Hall-E's recording folder. Manual local meeting deletion enumerates and removes local canonical/temporary copies but cannot promise immediate deletion from provider systems; provider retention follows the consented baseline and current provider terms.

## Rollback

Disable automatic briefing jobs while preserving transcript and prior briefing artifacts. A future direct-provider fallback requires explicit approval and a new decision; there is no silent non-Gemini fallback.

## Reconsider when

The selected Gemini model becomes unavailable, report quality fails validation, CLI/Gateway reliability is inadequate, or OpenClaw offers a narrower synchronous scoped API.
