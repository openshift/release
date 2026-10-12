# AGENTS.md — Guide for AI Coding Agents (OSC step-registry)

Guidance for AI agents (Claude Code and similar) authoring the **Sandboxed
Containers Operator (OSC)** reusable CI components — refs (steps), chains, and
workflows. It complements the human-focused `README.md`.

**Scope split** — three AGENTS.md cover OSC CI; keep changes in the right one:
- **This file** covers the *step-registry side in general*: refs, `-commands.sh`
  scripts, chains, workflows, and the runtime-container constraints that shape
  step scripts.
- The **testsuites post-suite pattern** (enable-gate, skipped-JUnit,
  `best_effort`, JUnit publishing, "add a new suite") lives in its own file next
  to those steps:
  [`testsuites/AGENTS.md`](testsuites/AGENTS.md).
- Pipeline images, `build_root`, `base_images`, and how a job is wired to a
  workflow live in the config guide:
  [`../../config/openshift/sandboxed-containers-operator/AGENTS.md`](../../config/openshift/sandboxed-containers-operator/AGENTS.md).

Read the repository-root `CLAUDE.md` first for general repo structure.

## Layout & Naming

- This file: `ci-operator/step-registry/sandboxed-containers-operator/AGENTS.md`
- A **ref** (step) is a dir with three files, all sharing the step name prefix:
  `<name>-ref.yaml`, `<name>-commands.sh`, `<name>-ref.metadata.json`. Each ref,
  chain, and workflow directory (and the top-level `sandboxed-containers-operator/`
  dir itself) also has an `OWNERS` file kept in sync with the config OWNERS via
  a script, not hand-edited — see
  [OWNERS Files](#owners-files--kept-in-sync-with-config-owners-via-sync-ownerssh)
  below.
- **Chains** (`<name>-chain.yaml`) order refs/chains; **workflows**
  (`<name>-workflow.yaml`) define full `pre`/`test`/`post` scenarios.
- Registry validation fails if a step dir contains any file whose name does not
  match the expected prefixes — **including editor swap files (`*.swp`)**. Close
  vim buffers / `:set noswapfile` before running `make`. `OWNERS` is the one
  standing exception to the name-prefix rule.

Key OSC components (testsuites/gate/workflow subsystem only — the full directory
also contains install, gather, peerpods, IPI, and miscellaneous steps; run
`/step-finder` before adding anything new to check for duplicates):
```
e2e/{azure,aro,aws}/…-e2e-{azure,aro,aws}-workflow.yaml   # top-level e2e scenarios
pre/sandboxed-containers-operator-pre-chain.yaml           # install/setup
test/sandboxed-containers-operator-test-chain.yaml         # shared test-phase chain (gate + openshift-extended-test)
testsuites-gate/                                            # test-phase step; creates ${SHARED_DIR}/testsuites_gate
testsuites/                                                 # POST-phase test suites (see testsuites/AGENTS.md)
```

## OWNERS Files — Kept in Sync with Config OWNERS via sync-owners.sh

Every `OWNERS` file in this tree — the top-level `sandboxed-containers-operator/OWNERS`
and one in every ref/chain/workflow subdirectory — is a **real file copy**,
kept identical to the single source of truth:
```
ci-operator/config/openshift/sandboxed-containers-operator/OWNERS
```
That config-side file is auto-generated and synced from the upstream
`openshift/sandboxed-containers-operator` repo's root `OWNERS` via
`https://github.com/openshift/ci-tools` tooling — see the
[Config AGENTS.md](../../config/openshift/sandboxed-containers-operator/AGENTS.md#owners-file--synced-from-upstream-single-source-of-truth)
for details. Never hand-edit a step-registry `OWNERS` file directly — ownership
changes belong upstream in the product repo; re-sync instead (see below).

### These must be real files, NOT symlinks to `../config/...`

A symlink from here out to `../../config/openshift/sandboxed-containers-operator/OWNERS`
looks like the obvious way to share one file, but it **breaks CI for the
entire `openshift/release` repo**: `generate-registry-metadata` (run by
`make registry-metadata`, part of `make update`, and by the repo-wide
`hack/validate-registry-metadata.sh` Prow check) operates on a **copy of this
`step-registry/` directory alone** — `ci-operator/config/` is never present in
that context — so a symlink pointing outside `step-registry/` resolves to
nothing there and the tool aborts hard for the whole registry (confirmed: this
exact symlink makes `make registry-metadata` fail with "missing OWNERS file"
for every affected path). This is also why every one of the 2,800+ *other*
OWNERS symlinks already in `ci-operator/step-registry/` (unrelated components)
only ever points to a parent directory **within `step-registry/` itself**
(`../OWNERS`) — never out to `config/`.

### Re-syncing

Whenever `ci-operator/config/openshift/sandboxed-containers-operator/OWNERS`
changes, re-run the sync script from the repo root and commit the result:
```bash
./ci-operator/config/openshift/sandboxed-containers-operator/sync-owners.sh
```
When adding a **new** step/chain/workflow directory, create its `OWNERS` by
re-running the script (it syncs every `OWNERS` file it finds under this tree)
rather than hand-copying one — then verify with:
```bash
make registry-metadata   # must complete with no "missing OWNERS file" errors
```

## Workflow Shape

The `e2e-{azure,aro,aws}` workflows run `pre` (provision + install OSC) → `test`
→ `post`. The `test` phase references the shared
`sandboxed-containers-operator-test` chain, which runs the `testsuites-gate` step
(creates `${SHARED_DIR}/testsuites_gate`) followed by `openshift-extended-test`.
Keeping the test phase in one chain means test-phase changes are made once and
apply to every workflow.

The **first** post entry is the `sandboxed-containers-operator-testsuites` chain,
followed by must-gather and deprovision. The workflows set
`steps.allow_best_effort_post_steps: true`, which is **required** for the
non-blocking suite behavior documented in `testsuites/AGENTS.md`.

**Gate:** the post suites read `${SHARED_DIR}/testsuites_gate` and skip when it is
absent. Because ci-operator does not reach the `test` phase when a `pre` step
fails, the gate file is only created when setup completed — so the post suites do
not run against a broken environment.

## Runtime Container Constraints (they shape `-commands.sh`)

### Non-root — you CANNOT `dnf install` at runtime
Step containers run under the OpenShift **restricted SCC** as an arbitrary
non-root UID. `-commands.sh` cannot install packages. Tools absent from the base
image must be either:
- downloaded as **static binaries** into a writable dir (`/tmp/bin`, prepended to
  `PATH`), or
- **baked into a pre-built image** at build time (see the runner-image option in
  the config AGENTS.md).

### Choosing the ref's base image (`from:`)
- Need **git**? Use `from: src` — `cli` and `upi-installer` do **not** ship git
  (an `upi-installer`-based step failed at runtime with `git: command not found`).
- Inject `oc` via the ref's `cli:` field, and symlink it as `kubectl` if the
  runner calls `kubectl`:
  ```yaml
  ref:
    from: src        # provides git
    cli: latest      # provides oc
  ```
- **Before switching a shared ref's `from:`**, read the graph-build coupling
  section in the config AGENTS.md: `from: src` needs `build_root` in *every*
  consuming config, and the change cannot be limited to one config or gated at
  runtime.

## Security & Supply Chain (required in `-commands.sh`)

- Keep `set -euo pipefail` **without** `-x`; add a comment stating so. `-x` traces
  every command with its arguments and leaks secrets.
- **Never `echo` credentials, tokens, cluster URLs, or kubeconfig.** A
  user-supplied tests-repo URL may embed credentials — log only sanitized
  metadata (e.g. the profile, and a boolean "custom repo set"), never raw runner
  arguments. Disable tracing around any unavoidable sensitive operation and
  restore the prior state.
- Pass data between steps via `${SHARED_DIR}`, not by echoing to logs.
- **Pin and verify every download**: version-pin the URL and check it with
  `sha256sum -c`. For sources without release binaries (e.g. `bats`), clone a
  **pinned tag** and verify the resulting **commit SHA** (content-addressed) so a
  re-pointed tag cannot swap the code.

## Verify Changes

```bash
make registry-metadata    # regenerate step metadata after adding/renaming steps
make jobs                 # runs checkconfig, which loads & validates the registry
```
`checkconfig` (run by `make jobs`) is the authoritative validation — it resolves
refs/chains/workflows and the image graph. Note: `make validate-step-registry`
may fail in some environments with `flag provided but not defined: -prow-config`
(a tooling/container mismatch, not your change); rely on `checkconfig`.

## Keeping This File Current

This file is living documentation — update it alongside any code change that
affects the information it describes. Examples of changes that require an
AGENTS.md update:

- Directory or file renames (steps, chains, workflows, subdirs).
- New steps/chains/workflows added to, or removed from, the Key OSC components
  list or the workflow-shape description.
- Changes to the `pre`/`test`/`post` phase structure of any workflow.
- New runtime container constraints or base-image guidance (`from:`, `cli:`).
- Security/supply-chain conventions that shift (e.g., new pinning requirements).
- The OWNERS sync convention changes (e.g., switching from `sync-owners.sh` to
  a different mechanism).

The linked AGENTS.md files ([testsuites/AGENTS.md](testsuites/AGENTS.md),
[Config AGENTS.md](../../config/openshift/sandboxed-containers-operator/AGENTS.md))
must be kept consistent — a change that touches the boundary between the two
scopes may need updates in both files.

## Related Documentation
- [Testsuites AGENTS.md](testsuites/AGENTS.md) — post-suite pattern & adding a new suite (kata-upstream is the reference example)
- [Config AGENTS.md](../../config/openshift/sandboxed-containers-operator/AGENTS.md) — pipeline images, build_root, graph-build coupling, job wiring
- Repository-root `CLAUDE.md` — general repo structure and step-registry system
- `README.md` (this dir) — human-focused step documentation
- [CI Operator Reference](https://steps.ci.openshift.org/ci-operator-reference) · [OpenShift CI Docs](https://docs.ci.openshift.org/)
