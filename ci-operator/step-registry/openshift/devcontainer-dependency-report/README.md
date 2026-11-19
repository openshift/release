# Devcontainer dependency report

This read-only checker inventories explicit dependency-version declarations in
the public `.devcontainer` definitions of `openshift/sippy`, `openshift/origin`,
and `openshift-eng/ship-status-dash`. One weekly Prow periodic per repository
uses the same `openshift-devcontainer-dependency-report` workflow in that
repository's `agentic-dev` image and publishes Markdown and JSON under its step
artifacts. It does not build target repository containers, change dependencies,
open pull requests, use credentials, or send external reports.

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

Only declarations containing an actual version token are inventory rows.
Unversioned OS package sets, installer URLs, module graphs, lockfiles, and
repository build targets remain owned by the target repository and are noted in
the report header instead of represented by brittle pseudo-version rows.
Repository-coupled values are reported only when an explicit token exists and
name the authority required for a change; they are never independently bumped.
Missing files, lookup failures, and zero or multiple extraction matches are
explicit errors and are never described as up to date.

The target source is not downloaded again: ci-operator builds `agentic-dev` from
the selected Prow checkout and that image places the repository at `/workspace`.
The checker verifies that the requested root is the Git top level and always
records the actual local `HEAD`, including merged-pull checkouts. It validates
repository identity from a public GitHub `origin` for on-demand runs, or from
the Prow `JOB_SPEC` workdir reference when clonerefs has no configured remote.
It also records whether the inventoried files are clean or dirty, so working-tree
content is never mislabeled as committed content.

## JSON report contract

The top-level `repository.revision` is the inspected checkout `HEAD`;
`repository.inventory_source` and `repository.checkout_identity` describe its
working-tree state and identity evidence. Each `results` row supplies
`repository`, `file` (the declaration location), `dependency`, `current`,
`proposed` (the advisory target, when any), `status`, `rationale`, `error`, and
`version_source` / `authority`. These stable fields are sufficient for a future
read-only watcher without adding update-PR or notification behavior.

Run the same checker on demand against a public target checkout:

```sh
python3 ci-operator/step-registry/openshift/devcontainer-dependency-report/openshift-devcontainer-dependency-report-commands.py \
  --repository openshift/sippy \
  --repository-root /path/to/sippy \
  --output-dir /tmp/devcontainer-dependency-report
```

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
selected repository, record the actual checkout `HEAD`, and identify the
embedded policy. This procedure is the dry run; the checker has no publication
or mutation mode.

The checker is syntax-compatible with Python 3.9 and uses only the standard
library plus the `git` executable already installed in each current
`agentic-dev` image.
