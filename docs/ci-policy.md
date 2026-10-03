# GitHub Actions and test spending policy

Owner decision: 2026-09-30. Applies to Codex, Claude Code, Antigravity and human operators across the owner's projects.

## Routine development

- Routine pushes and merges to main, PR creation, task completion and changing coding apps do not justify a hosted test run. Keep routine validation workflows on `workflow_dispatch`; preserve explicitly needed release tags, narrowly scoped infrastructure checks, security gates and scheduled operations.
- Choose local checks from the actual diff and its dependencies. For documentation/copy, check links, syntax or formatting as relevant; for styling, inspect the affected UI and run relevant checks; for a fix, run the regression test and affected callers; for a feature, run affected unit/integration tests. Run the affected critical E2E flow when behavior crosses UI/API/data boundaries.
- Broaden checks when shared code, dependencies, runtime/toolchain, authentication, security, migrations, data/methodology, failures or uncertain impact warrant it. A full suite is appropriate for a substantial integration batch or when a release gate requires it; it is not a ritual after each small edit or task.
- Record the commit or working-tree state, command and result. Reuse applicable passing evidence when the tested inputs, relevant dependencies, configuration, runtime and environment remain unchanged. A matching HEAD alone is insufficient in a dirty tree. Repeat only affected checks after changes; never reuse stale evidence or treat local results as hosted verification.
- One batch owner coordinates validation across agents and apps. Contributors provide their targeted evidence. Do not run duplicate full suites in parallel or rerun a passing unchanged batch solely because another agent takes over.

## Useful hosted verification

- Dispatch one explicit run for a stable candidate when independent hosted/cross-platform verification or an existing release/security gate requires it. Inspect existing exact-SHA runs first: reuse success, wait for active runs, inspect failure logs before any retry, and rerun only failed jobs when appropriate.
- Check current account allowance before optional dispatch. At 80% included usage, reserve the remainder for required releases/security checks; defer optional runs. Unknown or exhausted allowance means continue local development and report the hosted release blocker. Never raise the paid budget or buy capacity to complete a task.
- Keep the account Actions paid-overage budget at $0 with Stop usage enabled. Use standard runners; prefer Linux where equivalent. Larger runners are paid even with included allowance and are not authorized. Public-repository standard-runner discounts must not be confused with billable private usage.
- Bound validation jobs with suitable timeouts, cache dependencies, cancel only superseded validation in the same workflow/ref, and retain diagnostic artifacts briefly. Preserve release artifacts, backups and deployment jobs. Never cancel a release/deployment as validation cleanup.

## Release boundaries and adoption

- Preserve full required release/security/migration/backup coverage and existing branch protections, environments and approval requirements. Routine task completion and release readiness are different. Local targeted checks cannot replace a required exact-SHA hosted release gate.
- Inspect workflow triggers on the actual branch before pushing: old branches can restore automatic CI even after main becomes manual. Carry the adopted workflow changes forward when resuming those branches. Do not use `[skip ci]`, fabricated status checks or emergency overrides.
- GitHub controls workflow execution independently of agent instructions. Adopt this policy in each repository's workflows and instructions. Apply owner-wide changes only within the repositories explicitly requested; do not edit third-party/forked classroom repositories merely because they exist on the account.
- No budget increase, paid service, new runner installation or subscription change is authorized. A $0 cap prevents future paid usage; it cannot refund charges already accrued or guarantee unlimited hosted verification.
