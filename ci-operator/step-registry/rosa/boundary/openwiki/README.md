# Scheduled ROSA OpenWiki updates

The `rosa-boundary-openwiki-{prepare,update,publish}` refs support public and
private repositories that already have an initialized `openwiki/` wiki.
Boundary and Cora use the same refs, GitHub App, and existing
`rosa-boundary/ci/gcp-vertex-sa-key` credential; no per-repository copies are needed.

## Target configuration

Set these environment variables in the periodic's multi-stage steps:

- `TARGET_REPO`: GitHub repository in `owner/repo` form.
- `TARGET_BASE_BRANCH`: PR base (normally `main`).
- `TARGET_UPDATE_BRANCH`: persistent docs PR branch (normally `openwiki/update`);
  it must differ from the base.
- `TARGET_PERIODIC_JOB`: exact scheduled Prow job permitted to publish.

The Boundary defaults remain intact. Cora overrides only the target/job values
in `ci-operator/config/openshift-online/rosa-cora-agent/openshift-online-rosa-cora-agent-main__openwiki.yaml`.
Both periodics run Tuesday and Thursday at 16:00 UTC and enable private-job
configuration and Secrets Store CSI.

## Source and credential boundaries

1. **Prepare** mints a target-repository installation token with
   `contents:read` and `pull_requests:read`. It resumes the update branch only
   when an open PR targets the configured base **and its head repository is the
   target repository**, not a fork with a same-named branch. Otherwise it starts
   from the base, ignoring a closed PR's leftover branch.
   Authenticated Git access creates `openwiki-source.bundle`, containing the
   complete history of the base and, when needed, the update branch.
   `SHARED_DIR` receives only this flat bundle, the selected branch name, and
   the prepared PR number (or `none`). Git bundles do not carry local
   configuration, hooks, worktrees, or tokens.

2. **Update** clones the bundle without GitHub credentials and merges the base
   into a resumed update branch. It retains the pinned, SHA-verified Node
   download and OpenWiki toolchain, validates the existing Vertex key's project
   and service-account identity, disables LangChain tracing, and runs
   `openwiki code --update --print`. Defaults remain `gemini-enterprise`,
   `rosa-general`, `global`, and `claude-sonnet-5`.
   It emits only an `openwiki/` patch and flat version/model/status metadata;
   root agent guidance and transient `openwiki/.run.json` are excluded.

3. **Publish** uses a fresh authenticated checkout, never the model's worktree.
   Only the exact production job gets `contents:write` and
   `pull_requests:write`; `rehearse-*-${TARGET_PERIODIC_JOB}` gets read-only
   scopes. Rehearsals apply and validate the patch without committing, pushing,
   or calling PR APIs. Any source merge used for rehearsal validation remains
   uncommitted. Other job names are rejected before token creation.
   The publisher enforces the `openwiki/` path allowlist and whitespace checks,
   allows Markdown hard line breaks, verifies that the prepared PR identity
   is unchanged at startup and immediately before publishing, and leases every
   push against the observed branch tip. This also prevents recreating deleted
   PR branches or overwriting concurrent rewinds. PRs record Prow/model/version
   provenance.
   Production pushes only the update branch, never the base, and never
   automatically merges the PR.

If OpenWiki fails after completing pages, production still publishes the
completed docs with a **partial update** warning and then exits with OpenWiki's
nonzero status. Rehearsals and no-change runs also preserve that status.

## Before rehearsing or enabling another private target

The refs intentionally share the existing Boundary credentials. CI/App owners
must confirm:

- The existing GitHub App installation includes the target repository and grants
  the requested read scopes and production contents/PR write permissions.
- All four existing `rosa-boundary/ci` fields (`github-app-app-id`,
  `github-app-installation-id`, `github-app-pem`, and `gcp-vertex-sa-key`)
  are available through the job's GSM/Secrets Store CSI path.
- The existing Vertex service account is authorized for the configured model,
  quota covers the additional runs, and private source processing is approved.

A developer's personal `gh` access does not verify the CI App installation.
Avoid model-quota-consuming rehearsals until these checks are complete.
Then request only the target periodic, for example:

```text
/pj-rehearse periodic-ci-openshift-online-rosa-cora-agent-main-openwiki-openwiki-update
```

After merge, review the first generated docs PR rather than auto-merging it.
The target's unit/lint skip patterns are unchanged; whether to exempt all
OpenWiki JSON files is a separate owner decision.

## Local checks

```bash
bash -n ci-operator/step-registry/rosa/boundary/openwiki/prepare/rosa-boundary-openwiki-prepare-commands.sh
bash -n ci-operator/step-registry/rosa/boundary/openwiki/update/rosa-boundary-openwiki-update-commands.sh
bash -n ci-operator/step-registry/rosa/boundary/openwiki/publish/rosa-boundary-openwiki-publish-commands.sh
shellcheck ci-operator/step-registry/rosa/boundary/openwiki/{prepare,update,publish}/*-commands.sh
```
