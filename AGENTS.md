<!-- BEGIN MANAGED: github-actions-budget -->
## Verification and Actions spending

Owner decision 2026-09-30: read `docs/ci-policy.md` for the shared Codex, Claude Code and Antigravity policy. For routine task completion, select local checks from the changed behavior and affected dependencies, broaden when risk or failures require it, and reuse valid passing evidence for unchanged inputs. This replaces any blanket instruction to run a full suite after every small task. Full release/security/migration gates remain mandatory for the release candidate.

Routine main pushes and PRs do not require a hosted test run. One batch owner requests explicit hosted verification only when it serves a documented purpose and the included allowance permits it. Keep paid Actions overage at $0, preserve required release/security gates and protections, and inspect actual branch triggers before pushing older branches.
<!-- END MANAGED: github-actions-budget -->
