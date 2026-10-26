---
name: set-ocp-merge-criteria
description: >-
  Set or audit Tide merge criteria for an OpenShift repository in
  openshift/release. Use when configuring a repository assumed to follow the
  OCP development process, or when checking that its default, release, and
  fallback branch queries have the required labels.
---
# Set OCP Merge Criteria

Configure Tide in `core-services/prow/02_config/<org>/<repo>/_prowconfig.yaml`.
The repository is assumed to follow the OCP development process.

## Required query shape

Use up to three query groups, in this order:

1. **Release branches** (`release-X.Y` and, when applicable, `openshift-X.Y`)
   - Cover every existing release branch from 4.12 through the previous minor release.
   - The previous minor is the highest version in this query.
   - Require `approved`, `backport-risk-assessed`, `jira/valid-bug`, `lgtm`, and `verified`.
   - Do not require `jira/valid-reference` here.
2. **Default branch**
   - Require `approved`, `jira/valid-reference`, `lgtm`, and `verified`.
   - If the default branch is `main`, include only `main`.
   - Otherwise include both `master` and `main`.
3. **Complement**
   - Use `excludedBranches` containing every branch covered by the two queries above.
   - Require only `approved` and `lgtm`.

Every query uses this common `missingLabels` set:

```yaml
- backports/unvalidated-commits
- do-not-merge/hold
- do-not-merge/invalid-owners-file
- do-not-merge/work-in-progress
- jira/invalid-bug
```

## Release coverage

Gate every existing release branch from 4.12 through the minor release
immediately before the OCP version that the default branch's ci-operator config
promotes to. For example, if the default branch promotes to `ocp/5.1`, the
release query covers `release-4.16` through `release-5.0` when those branches
exist. It does not cover 5.1 or later.

If the repository has at least one `openshift-X.Y` branch, emit both the
`release-X.Y` and `openshift-X.Y` form for every covered version. If it has only
`release-X.Y` branches, emit only the `release-X.Y` form.

The complement still excludes every known release branch, plus the branches in
the default query. Historical release branches therefore remain outside the
strict release query while still not falling into the relaxed complement.

Always list branches explicitly. Do not use an omitted `includedBranches` field
or a wildcard for the default or release queries: `tide-config-manager` only
adds the `verified` label to queries that name `main`, `master`, or a versioned
branch. The complement query is the only query that should use
`excludedBranches`.

## Generate the queries

From the repository root, run:

```bash
python3 .claude/scripts/set_ocp_merge_criteria.py <org>/<repo>
```

The helper requires `gh` and `yq`.

The script reads the default branch and branch list from GitHub, reads the
default branch's ci-operator config to find its `ocp` promotion target, and
prints the ready-to-paste `queries:` block. Resolve an error about a
non-`main`/`master` default branch or an unexpected promotion target with the
repository owners instead of guessing.

If `gh` cannot read a private repository from the current environment, provide
the branch data explicitly with `--default-branch` and `--branches-file`.

Replace only the `queries:` block for the repository in its `_prowconfig.yaml`.
Preserve unrelated `tide` settings such as `merge_method`, and preserve other
top-level sections such as `branch-protection`.

## Audit and validate

Check the checked-in queries against the expected shape:

```bash
python3 .claude/scripts/set_ocp_merge_criteria.py <org>/<repo> --check
```

Then format and validate the Prow configuration:

```bash
make prow-config
make checkconfig
```

Do not push, comment on a PR, or otherwise publish the change unless explicitly
asked.
