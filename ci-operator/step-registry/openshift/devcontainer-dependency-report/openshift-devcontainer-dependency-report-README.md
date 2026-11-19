# Devcontainer dependency report

This read-only checker inventories dependency declarations in the public
`.devcontainer` definitions of `openshift/sippy`, `openshift/origin`, and
`openshift-eng/ship-status-dash`. One weekly Prow periodic per repository uses
the same `openshift-devcontainer-dependency-report` workflow in that
repository's `agentic-dev` image and publishes Markdown and JSON under its step
artifacts. It does not build target repository containers, change dependencies,
open pull requests, use credentials, or send external reports.

Pinned entries use a named public version source and an explicit inclusive /
exclusive policy range. Only stable three-part versions are candidates, and a
downgrade is never proposed. A candidate is not a compatibility claim. Floating,
repository-coupled, manual, and unsupported declarations are reported without a
proposal; repository-coupled entries name the authority that must approve a
change. Missing files, lookup failures, and zero or multiple extraction matches
are explicit errors and are never described as up to date.

The registry resolver delivers the checker script through the ci-operator
configuration. The script fetches the shared policy from public
`openshift/release` at an exact revision: the release pull revision from
`JOB_SPEC` in a rehearsal, or the resolved `main` revision in a normal periodic.
For a fork-based rehearsal, the report records the validated public fork as the
policy repository alongside that exact pull revision.
The target source is not downloaded again: ci-operator builds `agentic-dev` from
the selected job ref and that image places the repository at `/workspace`.
The checker reads declarations only from that local directory and records the
matching exact target revision from `JOB_SPEC` or the verified periodic checkout
described below. Both revisions are recorded in every report, and only the
selected repository is included. If revision or file selection is ambiguous,
the checker fails instead of inspecting another source.

Run the same checker on demand from an `openshift/release` checkout. A local
policy requires its revision to be stated explicitly:

```sh
revision=$(git rev-parse HEAD)
python3 ci-operator/step-registry/openshift/devcontainer-dependency-report/openshift-devcontainer-dependency-report-commands.py \
  --repository openshift/sippy \
  --repository-root /path/to/sippy \
  --config ci-operator/step-registry/openshift/devcontainer-dependency-report/openshift-devcontainer-dependency-report-config.md \
  --policy-revision "${revision}" \
  --output-dir /tmp/devcontainer-dependency-report
```

An on-demand run reads the selected local working-tree files. It records the
local `HEAD` as the base revision and records whether those inventoried files
are clean or dirty as `local-working-tree-clean` or
`local-working-tree-dirty`; it never describes working-tree content as commit
content. If `--repository-revision` is supplied, it must match local `HEAD`.
The generated periodics represent their target as the only `extra_refs` entry
without `base_sha`. ci-operator builds the source image from that ref through
clonerefs and copies its exact checkout to `/workspace`; the checker verifies
that `/workspace` is the Git root and records its `HEAD` with provenance
`periodic-checkout-head`. `pj-rehearse` converts one of these periodics to a
presubmit whose exact `openshift/release` pull is the primary ref and whose sole
target extra ref is the `/workspace` workdir. The checker recognizes that exact
generated rehearsal name and ref shape and records the target `HEAD` as
`rehearsal-checkout-head`; the release pull SHA remains the independent policy
revision. Other Prow shapes must provide a valid exact target SHA in `JOB_SPEC`
and record `job-spec-exact`.

## Rehearsal procedure

Current `pj-rehearse` discovery selects changed multistage ci-operator tests and
jobs that reference a changed registry node. Candidate periodics must be
non-hidden, have the generated
`pj-rehearse.openshift.io/can-be-rehearsed: "true"` label, and not be excluded
by the unrestricted-network rule. These three generated jobs meet those
requirements:

- `periodic-ci-openshift-sippy-main-agentic-periodic-sippy-devcontainer-dependency-report`
- `periodic-ci-openshift-origin-main-agentic-periodic-origin-devcontainer-dependency-report`
- `periodic-ci-openshift-eng-ship-status-dash-main-agentic-periodic-ship-status-dash-devcontainer-dependency-report`

The final diff adds only these three periodics, and the shared workflow is used
only by their three ci-operator tests. Still, do not rely on a bare
`/pj-rehearse`, because the affected set can change as the pull request changes.
In an authorized validation phase, first use `/pj-rehearse list` on the release
pull request to refresh the affected-job list. The current pj-rehearse plugin
supports space-separated exact job names, so select only these three with one
comment:

```text
/pj-rehearse periodic-ci-openshift-sippy-main-agentic-periodic-sippy-devcontainer-dependency-report periodic-ci-openshift-origin-main-agentic-periodic-origin-devcontainer-dependency-report periodic-ci-openshift-eng-ship-status-dash-main-agentic-periodic-ship-status-dash-devcontainer-dependency-report
```

A successful report-only rehearsal has three green rehearsal contexts, each
with a log summary ending in `errors=0`, and both
`devcontainer-dependency-report.json` and
`devcontainer-dependency-report.md` artifacts. Each artifact must name only its
selected repository and record both the policy and target revisions. This
procedure is the dry run; the checker has no publication or mutation mode.

The checker is syntax-compatible with Python 3.9 and uses only the standard
library. Current `agentic-dev` images install the distribution Python from their
Fedora 44 base. Inventory and extraction policy live in
`openshift-devcontainer-dependency-report-config.md` (raw JSON with a
registry-compatible documentation extension); add a new repository or
declaration there rather than adding repository-specific code.
