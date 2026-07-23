# Dependabot Triage Prow Job Design

**Jira:** CNTRLPLANE-2588
**Date:** 2026-01-21
**Author:** Bryan Cox

## Overview

Create a periodic Prow job that automatically triages dependabot pull requests in the HyperShift repository. The job runs weekly, queries all open dependabot PRs, processes them using Claude's `/fix-hypershift-repo-robot-pr` command, and consolidates all changes into a single reviewed PR.

## Goals

- Reduce manual maintenance burden for dependabot PRs
- Consolidate multiple dependency updates into a single reviewable PR
- Automate file regeneration (`make verify`, `make test`)
- Run weekly on Fridays at 12:00 UTC (7:00 AM ET)

## File Structure

### New Files (step-registry)

```
ci-operator/step-registry/hypershift/dependabot-triage/
├── setup/
│   ├── hypershift-dependabot-triage-setup-ref.yaml
│   └── hypershift-dependabot-triage-setup-commands.sh
├── process/
│   ├── hypershift-dependabot-triage-process-ref.yaml
│   └── hypershift-dependabot-triage-process-commands.sh
├── hypershift-dependabot-triage-workflow.yaml
├── OWNERS
└── README.md
```

### Modified Files

```
ci-operator/config/openshift/hypershift/openshift-hypershift-main.yaml
  → Add periodic job definition
```

### Auto-generated (via make update)

```
ci-operator/jobs/openshift/hypershift/openshift-hypershift-main-periodics.yaml
```

## Workflow Definition

```yaml
workflow:
  as: hypershift-dependabot-triage
  documentation: |-
    Periodic workflow that triages dependabot PRs in the HyperShift repository.
    Queries all open dependabot PRs, invokes Claude to process and consolidate
    them into a single PR with regenerated files.
  steps:
    pre:
      - ref: hypershift-dependabot-triage-setup
    test:
      - ref: hypershift-dependabot-triage-process
```

## Step Definitions

### Setup Step

**File:** `hypershift-dependabot-triage-setup-ref.yaml`

```yaml
ref:
  as: hypershift-dependabot-triage-setup
  documentation: |-
    Verifies Claude CLI is available and configures git credentials
    for fork and upstream authentication.
  from: cli
  credentials:
    - mount_path: /etc/claude-token
      name: claude-api-token
      namespace: test-credentials
    - mount_path: /etc/github-fork-token
      name: hypershift-community-github-app
      namespace: test-credentials
    - mount_path: /etc/github-upstream-token
      name: openshift-hypershift-github-app
      namespace: test-credentials
  commands: hypershift-dependabot-triage-setup-commands.sh
```

**Responsibilities:**
1. Install Claude CLI if not present
2. Verify Claude CLI works with the provided token
3. Configure git credential helper for fork vs upstream tokens
4. Clone hypershift repository from fork
5. Set up git remotes (origin = fork, upstream = openshift/hypershift)

### Process Step

**File:** `hypershift-dependabot-triage-process-ref.yaml`

```yaml
ref:
  as: hypershift-dependabot-triage-process
  documentation: |-
    Queries open dependabot PRs from openshift/hypershift, invokes Claude
    to process them using /fix-hypershift-repo-robot-pr, and consolidates
    all changes into a single PR. Uses best-effort processing.
  from: cli
  commands: hypershift-dependabot-triage-process-commands.sh
  resources:
    requests:
      cpu: 100m
      memory: 200Mi
  env:
    - name: REPO_OWNER
      default: openshift
    - name: REPO_NAME
      default: hypershift
    - name: FORK_OWNER
      default: hypershift-community
```

**Responsibilities:**
1. Query open dependabot PRs using `gh pr list`
2. Exit gracefully if no PRs found
3. Invoke Claude with consolidation instructions
4. Report results (successes, failures, final PR URL)

## Periodic Job Configuration

Addition to `openshift-hypershift-main.yaml`:

```yaml
- as: dependabot-triage
  cron: "0 12 * * 5"
  steps:
    cluster_profile: hypershift
    workflow: hypershift-dependabot-triage
```

## Claude Invocation

The Claude prompt instructs processing each PR individually with validation:

```
Phase 1: Setup
- Create branch 'fix/weekly-dependabot-consolidation' from upstream/main
- Initialize tracking for succeeded/failed PRs

Phase 2: Process Each PR (one at a time)
For each PR:
1. Save current HEAD SHA
2. Cherry-pick commits (convert to conventional format)
3. Run make verify
4. Run make test
5. Commit generated changes
6. If any step fails: reset to saved SHA, record failure, continue to next PR
7. If all pass: record success, move to next PR

Phase 3: Reorganize Commits
After all PRs processed, reorganize into logical groups:
1. go.mod/go.sum changes ONLY
2. vendor/ updates
3. api/ module changes
4. Regenerated assets
5. Other generated changes

Phase 4: Final Validation
- Run make verify (must pass)
- Run make test (must pass)

Phase 5: Create Consolidated PR
- Title: 'NO-JIRA: chore(deps): weekly dependabot consolidation'
- List all consolidated PRs with titles
- List failed PRs with reasons
- Close/comment on successfully processed original PRs

Phase 6: Report Results
```

**Key aspects:**
- Uses `--allowedTools "Bash,Read,Write,Edit,Grep,Glob,WebFetch,Skill,Task,TodoWrite"`
- JSON output format for structured results
- 100 max turns to handle multiple PRs
- Each PR validated independently before moving to next

## Authentication

Uses the fork pattern established by the jira-agent job:

| Token | Purpose | Repository |
|-------|---------|------------|
| Fork token | Push branches, create PRs | hypershift-community/hypershift |
| Upstream token | Close/comment on original PRs | openshift/hypershift |

Git credential helper prevents token exposure in logs.

## Failure Handling

**Best-effort processing with per-PR validation:**

Each PR is processed and validated independently:
1. Cherry-pick fails → reset branch, record failure, continue to next PR
2. `make verify` fails → reset branch, record failure, continue to next PR
3. `make test` fails → reset branch, record failure, continue to next PR
4. All steps pass → record success, proceed to next PR

**Result:**
- Consolidated PR includes only validated, passing changes
- Failed PRs remain open with failure reasons documented
- Clear audit trail of what succeeded and what failed

## Schedule

- **Cron:** `0 12 * * 5`
- **Frequency:** Weekly, Fridays
- **Time:** 12:00 UTC (7:00 AM ET)

## Dependencies

- Claude CLI with API token
- GitHub App tokens (fork + upstream)
- Same credential infrastructure as jira-agent job (CNTRLPLANE-2186)

## k8s.io / sigs.k8s.io Dependency Filtering

After fetching the list of open dependabot PRs and before processing, the workflow
filters out PRs that bump `k8s.io` or `sigs.k8s.io` dependencies. These dependencies
are managed manually by the team as part of coordinated Kubernetes rebase efforts and
should not be consolidated automatically.

**How it works:**

1. For each candidate PR, the workflow calls `gh api repos/openshift/hypershift/pulls/<number>/files`
   to retrieve the file-level patch data.
2. It inspects the patches for `go.mod` and `api/go.mod` specifically.
3. If any added line (lines starting with `+`, excluding the `+++` header) contains a
   `k8s.io/` or `sigs.k8s.io/` module path, the PR is excluded from processing.
4. Excluded PRs are logged and left open for manual handling.

This filtering runs after the `gh pr list` fetch and before the PR count check, so if
all open dependabot PRs are k8s.io bumps the job exits gracefully with nothing to do.

## Reference Implementation

Based on patterns from:
- jira-agent job: https://github.com/openshift/release/pull/70147
- `/fix-hypershift-repo-robot-pr` command in hypershift repo
