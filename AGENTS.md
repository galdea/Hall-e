<!-- BEGIN MANAGED: github-actions-budget -->
## Verification and Actions spending

Owner decision 2026-09-30: read `docs/ci-policy.md` for the shared Codex, Claude Code and Antigravity policy. For routine task completion, select local checks from the changed behavior and affected dependencies, broaden when risk or failures require it, and reuse valid passing evidence for unchanged inputs. This replaces any blanket instruction to run a full suite after every small task. Full release/security/migration gates remain mandatory for the release candidate.

Routine main pushes and PRs do not require a hosted test run. One batch owner requests explicit hosted verification only when it serves a documented purpose and the included allowance permits it. Keep paid Actions overage at $0, preserve required release/security gates and protections, and inspect actual branch triggers before pushing older branches.
<!-- END MANAGED: github-actions-budget -->

<!-- BEGIN MANAGED: release-verification -->
## Faster, safe release verification

Owner adoption 2026-10-28: read `docs/release-verification-policy.md` with this repository's CI policy and release runbook before changing verification or requesting a release. One batch owner coordinates local evidence across coding agents. Preflight the exact clean candidate and complete batch baseline; preserve every release/security/browser/migration/backup gate, isolate parallel lanes, and require complete exact-revision evidence. Measure runner minutes as well as elapsed time. Routine work uses diff-appropriate local checks; hosted spending and deployment need their existing authorization. Current paid Actions overage policy is $0 with Stop usage; do not change billing.
<!-- END MANAGED: release-verification -->

## Model routing and independent review

Owner preference (2026-11-20, `~/.codex/skills/buzz-claude-workflow/references/model-selection.md`): keep Dot on OpenAI. Assign repository implementation, multi-file fixes and UI polish primarily to Claude Code (Opus 5.5, or Fable 5.2 when eligible), and long-context investigation or cross-file evidence to Gemini 4 Neon (or Hydrogen for bounded extraction/tests; earlier Gemini routes are retired). For independent technical review, use an eligible provider distinct from the author/candidate rather than two models from the same provider, and follow the quota-handoff rules without silently substituting a required separate-provider gate.
