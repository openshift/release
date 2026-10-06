# AGENTS.md — Guide for AI Coding Agents (OSC CI config / pipelines)

Guidance for AI agents (Claude Code and similar) working on the **Sandboxed
Containers Operator (OSC)** `ci-operator` **configuration** — the pipeline
(images, build_root, releases) and the periodic/e2e job definitions. It
complements the human-focused `README.md`.

**Scope split** — keep changes in the right place:
- **This file** covers the *config side*: pipeline images, `build_root`,
  `base_images`, `releases`, and the `tests` that wire jobs to workflows.
- Step/chain/workflow authoring (the reusable `-commands.sh`, refs, chains,
  post-suite patterns, runtime container constraints) lives in
  [`../../../step-registry/sandboxed-containers-operator/AGENTS.md`](../../../step-registry/sandboxed-containers-operator/AGENTS.md).

Read the repository-root `CLAUDE.md` first for general repo structure.

## File Location & Layout

- This file: `ci-operator/config/openshift/sandboxed-containers-operator/AGENTS.md`
- Generated Prow jobs (never edit by hand): `ci-operator/jobs/openshift/sandboxed-containers-operator/`

The OSC configs are **variant** configs of the `devel` branch:

```
openshift-sandboxed-containers-operator-devel.yaml               # main devel: builds operator+bundle images, has build_root
openshift-sandboxed-containers-operator-devel__downstream-candidate.yaml     # "candidate" variant
openshift-sandboxed-containers-operator-devel__downstream-candidate4NN.yaml  # per-release candidate variants (currently 420..422)
openshift-sandboxed-containers-operator-devel__downstream-release.yaml       # release variant
openshift-sandboxed-containers-operator-osc-release-v1.10.yaml               # osc-release stream
```

The downstream variants install OSC from a **released catalog** rather than
building the product, so historically they build no images, promote nothing, and
have no `build_root`. They exist per-release because CI analytical tooling needs
release-specific data. Each defines periodic `azure-ipi-kata`,
`azure-ipi-peerpods`, `azure-ipi-coco`, `aro-*`, `aws-*` tests that reference the
`sandboxed-containers-operator-e2e-{azure,aro,aws}` workflows.

Because these variants are near-identical, a change to a shared test step
usually has to be applied to **all** of them at once — see graph-build coupling
below.

## Pipeline Images Primer

`ci-operator` builds a pipeline image graph per config:
`pipeline:root` → `pipeline:src` → any images in `images:`.
- `src` = the `build_root` image with the tested repo checked out. It therefore
  requires a `build_root`, and it carries whatever the build_root base provides
  (notably **`git`**, which the `cli` and `upi-installer` base images do NOT).
- `base_images:` pulls named images into the pipeline for steps to consume via
  `from:`.
- A ref's `cli:` field injects `oc` into the step container independent of
  `from:`.

### `from: src` requires a `build_root` in the config
If any step in a config's jobs uses `from: src`, that config MUST declare a
`build_root` or it fails at **graph-build time**. Mirror the operator repo's
`devel` build_root:
```yaml
build_root:
  image_stream_tag:
    name: builder
    namespace: ocp
    tag: rhel-9-golang-1.26-openshift-4.23
```

### ⚠️ Graph-build coupling — the #1 gotcha
A **shared step ref's** `from:` image is resolved for **every** config that
includes the step, *before* any runtime logic runs. Consequences:
- Changing a shared ref to `from: src` (or to a custom built image) forces you to
  add the prerequisite (`build_root`, or the image build) to **all consuming
  configs simultaneously** — there is no "just candidate422 first".
- A runtime enable-gate (`TESTS_<SUITE_NAME>_ENABLE: "false"`) does **not** prevent a
  graph-build failure. The image must resolve even for jobs that will skip the
  step.

### Custom runner image (alternative to runtime downloads)
The repo convention for test runners is a **pre-built image** consumed via
`from:`. One can be built with an `images:` entry (`dockerfile_literal` for an
inline Dockerfile, `dockerfile_path` for a checked-in one, or build-and-promote
to a shared namespace consumed via `base_images`) that bakes in the tools a step
needs (`git`, `jq`, `yq`, `bats`, …). Building any `images:` entry also needs a
`build_root` (the build context is `src`), and pointing a shared step at the
built image hits the same graph-build coupling as `from: src`. See the
step-registry AGENTS.md for how the step's `from:` selects between `src` and a
runner image.

## Nightly Periodic Jobs

Each downstream-candidate variant defines one periodic per job type. Jobs that
are not yet enabled use the placeholder cron `0 0 31 2 1` (February 31 — a date
that never exists, so the job is registered but never fires). **Do not delete
these placeholder entries** — they keep the config structurally complete and make
activation a single-line diff.

### Job types and current status

| Job | Azure | AWS | ARO |
|-----|-------|-----|-----|
| `*-kata` | ✅ active | — | — |
| `*-peerpods` | ✅ active | ✅ active | disabled (placeholder) |
| `*-coco` | disabled (placeholder) | — | disabled (placeholder) |

Update this table whenever a job type is activated or disabled.

### Scheduling conventions

All active nightly jobs run **weekdays only** (`cron: MM HH * * 1-5`). Within
each job type, variants are staggered by **5 minutes** with the newest OCP
version getting the earliest slot:

```
Variant    4.22   4.21   4.20
---------- -----  -----  -----
azure-kata  5 0   10 0   15 0     # window 00:05–00:15, ~3h jobs
azure-pp   20 3   25 3   30 3     # window 03:20–03:30 (after kata closes)
aws-pp      6 0   11 0   16 0     # parallel with Azure (no shared capacity)
```

**Azure capacity constraint:** Azure is shared and each job runs ~3h. New Azure
job types must be scheduled into a non-overlapping window after the previous
window closes. The current kata window (00:05–00:15 start, done by ~03:05–03:15)
is followed by the peerpods window (03:20–03:30).

**AWS runs in parallel with Azure** — there is no shared capacity constraint, so
AWS jobs slot into the same early window (00:06–00:16) with a 1-minute drift
from the Azure kata slots to avoid Prow API collisions.

### Conventions when enabling a new job type

1. Apply to **all active downstream-candidate variants at once** (420, 421, 422)
   in a single PR — partial activation creates inconsistent coverage.
2. Choose the next available window (for Azure) or drift slightly within an
   existing window (for AWS/parallel providers).
3. Stagger the three variants 5 minutes apart; put the newest OCP release first.
4. For providers not yet ready, leave the cron as the placeholder `0 0 31 2 1`.
5. Run `make jobs` after editing and commit both the config and the regenerated
   files under `ci-operator/jobs/`.

### Keeping the nightly schedule current

Update this section whenever a new job type is activated or disabled, a window
shifts, or a new provider is added. Include the reason for any window change so
the next editor can see why the current layout exists.

## Verify Changes

Always regenerate and validate after editing configs:
```bash
make ci-operator-config   # determinize config formatting & key ordering
make jobs                 # prowgen + checkconfig + sanitize
```
`make jobs` runs **`checkconfig`**, which resolves the image graph — this is what
catches `from:`/`build_root` mistakes locally. Commit the edited configs **and**
any regenerated files under `ci-operator/jobs/`. Never hand-edit `ci-operator/jobs/`.

Notes:
- openshift/release presubmits are rehearsed with **`/pj-rehearse <job-name>`**,
  not `/test`.
- The downstream periodic jobs provision real clusters (~2h). Get config and
  graph resolution correct locally *before* spending a cluster run.

## Keeping This File Current

This file is living documentation — update it alongside any code change that
affects the information it describes. Examples of changes that require an
AGENTS.md update:

- New config variant files added or removed (update the file listing and the
  per-release candidate range).
- `build_root` image tag bumped (update the example snippet).
- New `base_images` or pipeline-image patterns introduced.
- Graph-build coupling rules change (e.g., a new way to share step images).
- Test names or workflow references added to/removed from the config variants.
- A nightly job type is enabled, disabled, or rescheduled (update the Nightly
  Periodic Jobs section — table, schedule block, and window rationale).

The linked AGENTS.md files
([Step-registry AGENTS.md](../../../step-registry/sandboxed-containers-operator/AGENTS.md),
[Testsuites AGENTS.md](../../../step-registry/sandboxed-containers-operator/testsuites/AGENTS.md))
must be kept consistent — a change that touches the boundary between the two
scopes may need updates in both files.

## Related Documentation
- [Step-registry AGENTS.md](../../../step-registry/sandboxed-containers-operator/AGENTS.md) — steps/chains/workflows authoring
- Repository-root `CLAUDE.md` — general repo structure and workflows
- `README.md` (this dir) — human-focused config guide
- [CI Operator Reference](https://steps.ci.openshift.org/ci-operator-reference) · [OpenShift CI Docs](https://docs.ci.openshift.org/)
