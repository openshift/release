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
It captures every inventoried file once before public version lookups, hashes
those bytes with the file's Git attributes, and compares the result with the
recorded `HEAD`. This keeps later working-tree edits from being mislabeled as
committed content.

## JSON report contract

The top-level `repository.revision` is the inspected checkout `HEAD`;
`repository.inventory_source` and `repository.checkout_identity` describe its
working-tree state and identity evidence. Each `results` row supplies
`repository`, `file` (the declaration location), `dependency`, `current`,
`proposed` (the advisory target, when any), `status`, `rationale`, `error`, and
`version_source` / `authority`. These stable fields are sufficient for a future
read-only watcher without adding update-PR or notification behavior.

## Release-owned agentic-ci advisory

The three weekly jobs already run this step in their respective `agentic-dev`
images. The `agentic` variants build that image from the inputs below, copy the
target repository to `/workspace`, and install `agentic-ci` with
`python3 -m pip install` and an exact pin in the inline Dockerfile.

| Target repository | Devcontainer input image stream tag |
|---|---|
| `openshift/sippy` | `ci/sippy:sippy-devcontainer` |
| `openshift/origin` | `ci/origin-devcontainer:origin-devcontainer` |
| `openshift-eng/ship-status-dash` | `ci/ship-status-dash:ship-status-dash-devcontainer` |

The same report command reads the running interpreter's version and installed
distribution metadata via `importlib.metadata`. On-demand runs observe the local
interpreter. The reference's `run_as_script` runs the report directly. This
check reads metadata without importing or dispatching the package CLI.

`agentic-ci-advisory.json` records the observation, source config path, status
and candidate. The Markdown has a separate openshift/release section. Advisory
outcomes are independent of the schema-1 target-repository JSON, inventory
counts, and exit status. Both core inventory artifacts are written before the
advisory lookup starts. `candidate_available` means a strictly newer final
`0.5.x` release has a non-yanked `py3-none-any` wheel whose PyPI metadata
supports the observed final Python version. The checker bounds the PyPI lookup
to 30 seconds and 2 MiB and accepts an inclusive Python minimum, optionally with
an exclusive maximum.
It lists newer final series for review. Missing observations, lookup failures,
and newer patches without supported wheel evidence produce `unverified` when
no candidate can be established.

The target checkout revision identifies the repository copied into the image.
The release configuration is supplied separately to ci-operator. This step
has neither a verified release config commit nor the three pin declarations
from one snapshot. The advisory therefore leaves the config revision and pin
unset. Matching observations across jobs are evidence about those runtimes.

### Review a grouped bump in openshift/release

1. Resolve current public `openshift/release` main to one full commit. Read the
   three `__agentic.yaml` config blobs from it and verify that each
   `agentic-dev` definition has one active exact pin and that all three pins
   agree. Recheck public PyPI and verify the exact candidate wheel against the
   Python versions for all three build inputs.
2. Change the three pin values together. Run `make update` and `make checkconfig`
   and review the diff. Build each exact-candidate `agentic-dev` image in a
   build-only environment without promotion. Record image IDs and verify both
   Python and `importlib.metadata.version("agentic-ci")` in each result.
3. Run an import-only CLI smoke for each built image with the entrypoint
   overridden, networking disabled, and no credentials or host mounts.
   Verify the candidate's console entry point can be imported without dispatch.
   Keep solver workflows out of the check. `EVAL_MODE` can still publish.
4. Recheck main and PyPI before opening one human-reviewed PR with the commit,
   candidate and validation evidence. Use an existing PR for the same bump,
   leave maintainer-closed bumps closed, and keep auto-merge disabled.

## Running on demand

Run the same checker on demand against a public target checkout:

```sh
python3 ci-operator/step-registry/openshift/devcontainer-dependency-report/openshift-devcontainer-dependency-report-commands.py \
  --repository openshift/sippy \
  --repository-root /path/to/sippy \
  --output-dir /tmp/devcontainer-dependency-report
```

The checker is syntax-compatible with Python 3.9 and uses only the standard
library plus the `git` executable already installed in each current
`agentic-dev` image.
