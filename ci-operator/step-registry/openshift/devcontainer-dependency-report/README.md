# Devcontainer and agentic CI dependency report

This read-only checker inventories explicit dependency declarations in two
scopes: the public `.devcontainer` definitions of `openshift/sippy`,
`openshift/origin`, and `openshift-eng/ship-status-dash`; and the agentic CI
tooling declarations owned by `openshift/release`. One weekly Prow periodic per
target repository uses the same `openshift-devcontainer-dependency-report`
workflow, with source staging isolated to a report-only pre-step and checking in
that repository's existing `agentic-dev` image. It publishes Markdown and JSON
under its step artifacts. It does not build target repository containers, change
dependencies, open pull requests, use credentials, or send external reports.

The checker and its policy data are a single co-versioned step-registry script.
Dependency definitions are centralized once, while each repository declares a
short list of the definitions it uses. Add a source identifier, dependency
definition, or repository list entry there rather than adding lookup logic.

Pinned entries use a named public version source and an explicit inclusive /
exclusive policy range. Only exact stable three-part versions are candidates,
and a downgrade is never proposed. A candidate is not a compatibility claim.
GitHub-hosted projects are discovered through public Git tags with `git
ls-remote`; the report deliberately describes them as tags, not as GitHub
Release publication metadata. npm uses its abbreviated install metadata and
filters deprecated releases. PyPI candidates require a non-yanked file.

Only actual declarations with an explicitly extracted token are inventory rows.
Unversioned OS package sets, installer URLs, module graphs, lockfiles, and
repository build targets remain owned by the target repository and are noted in
the report header instead of represented by brittle pseudo-version rows.
Repository-coupled values are reported only when an explicit token exists and
name the authority required for a change; they are never independently bumped.
Missing files, lookup failures, and zero or multiple extraction matches are
explicit errors and are never described as up to date.

The agentic CI scope includes each target's exact `agentic-ci` pip pin from its
`__agentic.yaml`, the shared Codex version and architecture checksums from
`openshift-agentic-trt-init-model`, and the unversioned Claude installer URL
from the normal `openshift-agentic-trt-jira-solver`. The three `agentic-ci` pins
share one update group because any future change belongs in one
`openshift/release` pull request, not three target-repository pull requests.
The Codex version and checksums are repository-coupled and receive no independent
proposal. The Claude installer URL is explicitly floating; the report does not
invent a pin.

The target source is not downloaded again: ci-operator builds `agentic-dev` from
the selected Prow checkout and that image places the repository at `/workspace`.
The checker verifies that the requested root is the Git top level and always
records the actual local `HEAD`, including merged-pull checkouts. It validates
repository identity from a public GitHub `origin` for on-demand runs, or from
the Prow `JOB_SPEC` workdir reference when clonerefs has no configured remote.
It captures every inventoried file once before public version lookups, hashes
those bytes with the file's Git attributes, and compares the result with the
recorded `HEAD`. This keeps later working-tree edits from being mislabeled as
committed content.

The release-owned declarations are not fetched by the checker. For a normal
periodic, generation adds an explicit `openshift/release` `extra_ref` while the
target ref remains the Prow workdir. ci-operator clones both refs into its `src`
image. A workflow pre-step running only for the report stages the five paths
listed in `hack/devcontainer-dependency-report-source-files.txt`, the actual
release checkout `HEAD`, and their SHA256 manifest in `SHARED_DIR`. Existing
agentic jobs continue to use the unchanged `agentic-dev` image and do not require
the release checkout. For a pull-request rehearsal, pj-rehearse uses the release
PR as primary refs, drops the duplicate release `extra_ref`, and marks the
remaining target ref as workdir. The pre-step therefore receives the candidate
release checkout and target checkout without duplicate clone paths. The checker
validates the staged hashes before any public version lookup and records release
provenance separately from the target checkout.

## JSON report contract

The top-level `repository.revision` is the inspected target checkout `HEAD`;
`repository.inventory_source` and `repository.checkout_identity` describe its
working-tree state and identity evidence. `release_source` separately records
the exact staged release revision, source type, identity, and any source error.
Each `results` row supplies the report target `repository`, `scope`, declaration
`source_repository`, `source_file`, `source_revision`, `owner_repository`,
`update_group`, `dependency`, `current`, `proposed` (the advisory target, when
any), `status`, `rationale`, `error`, and `version_source` / `authority`. These
fields are sufficient for a future read-only watcher without adding update-PR
or notification behavior.

Run the same checker on demand against a public target checkout:

```sh
python3 ci-operator/step-registry/openshift/devcontainer-dependency-report/openshift-devcontainer-dependency-report-commands.py \
  --repository openshift/sippy \
  --repository-root /path/to/sippy \
  --release-source-root /path/to/openshift-release \
  --output-dir /tmp/devcontainer-dependency-report
```

The local release source must be an `openshift/release` Git checkout. The report
records its actual `HEAD` and whether the selected inputs differ from that commit;
it never substitutes a branch name or inferred Prow revision.

## Rehearsal procedure

On the `openshift/release` pull request, use `/pj-rehearse list` to refresh the
affected-job list. Select only the exact report job names returned by that list:

```text
/pj-rehearse <first-devcontainer-dependency-report-job> [<next-report-job> ...]
```

A successful report-only rehearsal has one green rehearsal context per selected
job, a log summary ending in `errors=0`, and both
`devcontainer-dependency-report.json` and
`devcontainer-dependency-report.md` artifacts. Each artifact must name only its
selected target repository, record the actual target checkout `HEAD`, record the
candidate `openshift/release` source revision, and identify the embedded policy.
The new rows must identify their declaration source as `openshift/release` and
must not be attributed to the target `HEAD`. This procedure is the dry run; the
checker has no publication or mutation mode.

The checker is syntax-compatible with Python 3.9 and uses only the standard
library plus the `git` executable already installed in the current source and
`agentic-dev` images.
