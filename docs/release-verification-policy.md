# Faster, safe release verification

Owner adoption: 2026-10-28. Applies to all coding agents and human operators. Read this with the repository's CI policy and release runbook. Preserve repository-specific release, security, privacy, migration, backup, browser and approval requirements. These instructions do not authorize deployment or hosted spending.

## Candidate and local preflight

- One batch owner coordinates validation across agents, apps and worktrees. Contributors provide targeted evidence; changing agents does not justify repeating unchanged passing checks.
- Inspect the actual branch, integration base, workflow triggers, supported runtime, release procedure and current verification before editing CI or pushing an old branch. Preserve concurrent work. Prepare changes separately while a release candidate is being verified; adopting a workflow change creates a new candidate requiring its own applicable verification.
- Select routine local checks from the diff and its dependencies. Before a release dispatch, check the exact clean committed candidate against the actual previous verified or released ancestor covering the entire batch. Record why the baseline is complete: ancestry alone does not establish that. Before dispatch, the batch owner must cite or attach the prior successful exact-SHA verification run or accepted release ledger establishing this baseline and explain why it covers the whole batch.
- Put cheap likely failures early: formatting of the entire unreleased batch, relevant lint/types/regressions, production build and applicable bundle limits, routing and static readiness. Keep broader local release/E2E gates when policy or impact requires them. Do not invent unavailable commands or treat a missing required check as a pass.
- Save a local receipt outside the candidate tree with candidate SHA/tree, clean/dirty state, baseline and its justification, commands, relevant runtime/configuration/environment, results and explicit skips. Check the candidate state again after execution. Redact credentials. A preview or synthetic test receipt is not a successful candidate preflight; local evidence never substitutes for required hosted release evidence.

## Hosted evidence and spending

- Routine pushes, PRs, merges, task completion and switching coding apps do not justify hosted validation. Keep routine validation manual; preserve required release tags, security checks, schedules and scoped deployment/infrastructure triggers.
- Reuse applicable exact-revision evidence or wait for an active run. Diagnose failures before retrying. One authorized stable-candidate comparison is enough; do not dispatch to inspect status.
- The current owner policy is paid Actions overage **$0 with Stop usage enabled**. Do not change account settings, buy capacity, install runners or increase any budget. Check included allowance before optional dispatch; defer optional work at 80% consumed or when allowance is unknown/exhausted. Required hosted release gates remain blocking when unavailable. Use standard runners, preferring Linux where equivalent.
- Record queue time, job/step duration, elapsed critical path, setup/download overhead, total runner minutes and reliability. A shorter wait alone does not establish a cost or reliability improvement. Never promise unlimited free runs.

## Safe concurrency and release acceptance

- Inventory the old gate set before splitting jobs. Parallelize only independent lanes with isolated ports, servers, credentials, databases, fixtures and build outputs. Retain existing assertions, test enumeration and checkout/security prerequisites on each applicable runner.
- A final aggregate runs after all required dependencies, even if they failed, and explicitly requires each dependency's result to be `success`. Missing, duplicate, failed, skipped, cancelled, timed-out or mismatched evidence must block release. Verify every expected shard identity exactly once; a shard count alone is insufficient.
- Bind evidence to the candidate's actual workflow contract, repository, exact tested SHA, allowed event/ref, workflow path/revision and run ID. A named green check alone is insufficient. Require completed successful checkout evidence and all applicable lanes. Never combine independent runs, branch review evidence and release evidence, or synthetic PR merges and main candidates.
- Define rerun acceptance before enabling failed-job-only recovery. GitHub may retain successes from earlier attempts of the same run. Accept those only if the checker establishes the unchanged workflow/SHA/ref, the complete expected job set and latest applicable successful result for every job. Otherwise fail closed and explain the limitation. Do not silently demand an expensive full rerun or invent success. A newer failed rerun of a job must not be hidden by its earlier success.
- Update workflow structure, dispatch/request logic, scope tests, evidence checker and release documentation together. Exercise negative cases: incomplete/duplicate shards, omitted gates, wrong SHA/ref/workflow/run/attempt, absent checkout and fabricated success. Preserve applicable successful legacy evidence under the workflow that actually produced it; do not apply a new job layout retroactively.
- Cache only deterministic inputs with adequate keys. A cache miss or stale/corrupt cache must not make a required gate pass. Reuse immutable artifacts only with matching commit, runtime, configuration and relevant input provenance.
- Keep backup, migration, active-user/data safety, entitlement, deployment and smoke-check ordering unless independence is demonstrated. Preserve branch protections, environments, approvals, historical evidence and failure records. Roll back an unreliable CI change through normal review; do not bypass a gate.

## Browser coverage and adoption

- Inventory actual browser projects/installations, engines, devices, emulation, critical flows and triggers. Chromium with an iPhone viewport is not Safari; Playwright WebKit is not shipping Safari on a real Apple device. Record actual coverage without implying a support guarantee.
- Preserve existing required coverage. Obtain the relevant product decision before adding, removing or downgrading browser support, including any real Safari/macOS/iOS or Opera requirement. Do not add an Opera lane merely because Chromium is tested. Measure a small isolated matrix before expanding cost.
- Adapt this policy to each active project. Desktop/native repositories retain their platform/package/install gates; static projects do not acquire an invented backend workflow. Global defaults cover future work. Do not bulk-rewrite classroom/third-party forks or dormant repositories.
- Accept concurrency changes only when all prior gates remain blocking and targeted negative tests pass. Record any hosted performance comparison as pending until an authorized run measures it; do not claim speedup from job layout alone.

References: [GitHub reruns](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/re-run-workflows-and-jobs), [GitHub job dependencies](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-jobs).
