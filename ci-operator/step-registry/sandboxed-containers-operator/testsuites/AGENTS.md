# AGENTS.md — Guide for AI Coding Agents (OSC testsuites)

Guidance for AI agents (Claude Code and similar) adding or changing an **OSC
POST-phase test suite** under this `testsuites/` directory. It complements the
human-focused `README.md`.

We expect contributors to add more suites over time. **`kata-upstream` is the
reference implementation** — copy its shape and follow the conventions below so
every suite behaves consistently in the post chain. `osc` follows the same
conventions and runs the operator's **golang (Ginkgo v2) e2e tests** via
`go test` (on `from: src` for the Go toolchain) — use it as the template when your
suite is `go test`-based. `caa` is the reference for two additional patterns: suites
that need an independent cloud API client sourced from `${CLUSTER_PROFILE_DIR}` (see
convention 8 below), and the complete no-results failure path (results-tree dump +
failing JUnit artifact — convention 4).

**Scope split** — three AGENTS.md cover OSC CI:
- **This file** covers *authoring a test suite*: the post-suite pattern, the
  conventions every suite must follow, and the "add a new suite" recipe.
- General step-registry rules (ref/chain/workflow layout, runtime container
  constraints, security & supply-chain, base-image `from:` choice) live one level
  up: [`../AGENTS.md`](../AGENTS.md).
- Pipeline images / `build_root` / job wiring live in the config guide:
  [`../../../config/openshift/sandboxed-containers-operator/AGENTS.md`](../../../config/openshift/sandboxed-containers-operator/AGENTS.md).

Read the repository-root `CLAUDE.md` first for general repo structure.

## How the suites run

Each suite is an independent step dir under `testsuites/`. All suites are wired
into `sandboxed-containers-operator-testsuites-chain.yaml`, which runs as the
**first** operation of the OSC e2e workflow's `post` phase (before must-gather
and deprovision). Every step in the chain is `best_effort: true`.

Non-blocking behavior **requires** the referencing workflow to set
`steps.allow_best_effort_post_steps: true` (the `e2e-{azure,aro,aws}` workflows
do). Without it, `best_effort` is ignored and a failing suite blocks the rest.

### Gate

The post suites run in `post`, which ci-operator executes **even when `pre` (setup)
failed** — so without a guard they run against a broken cluster and emit a flood of
meaningless failures. The guard is the `testsuites-gate` step (at the component
root, `testsuites-gate/`): it runs in the **`test` phase** (via the shared
`sandboxed-containers-operator-test` chain, before `openshift-extended-test`) and
creates the file `${SHARED_DIR}/testsuites_gate`. Each post suite skips when that
file is absent.

This leans on a ci-operator behaviour: **a failed `pre` step skips the entire `test`
phase**, so the gate step never runs, the file is never created, and every post suite
skips on its own. The gate check is existence-only — the file is empty and its
presence is the sole signal.

## Conventions every suite MUST follow

1. **Name every env var `TESTS_<SUITE_NAME>_<PARAMETER>`.** All parameters a
   suite exposes — including the enable-gate — share this prefix, where
   `<SUITE_NAME>` is the suite's name upper-cased with `-` → `_`. For
   `kata-upstream`:
   - `TESTS_KATA_UPSTREAM_ENABLE` — the enable-gate
   - `TESTS_KATA_UPSTREAM_PROFILE`, `TESTS_KATA_UPSTREAM_REPO`,
     `TESTS_KATA_UPSTREAM_REPO_REF` — suite parameters

   This keeps every suite's variables grouped and unambiguous across the shared
   post chain. Do **not** invent other shapes (`TEST_…`, `<SUITE>_TESTS_…`).
2. **Enable-gate, skip-by-default.** Read `TESTS_<SUITE_NAME>_ENABLE` (env on the
   ref, `default: "false"`). The suite is opt-in; it must never run — or block —
   unless a config explicitly sets it `"true"`.
3. **Skip cleanly when disabled.** Write a *skipped* JUnit to `${ARTIFACT_DIR}`
   and `exit 0`. Never leave prow with zero results.
3b. **Honor the gate.** Immediately *after* the enable-gate, check
   `${SHARED_DIR}/testsuites_gate`. If the file is absent, skip: write a *skipped*
   JUnit with the message `gate does not exist` and `exit 0`. Existence is the
   only signal — do not inspect the file's content. Copy the block from `osc/` or
   `kata-upstream/`.
4. **Publish results, and fail if there are none.** Copy each JUnit to
   `${ARTIFACT_DIR}/junit_<suite>_*.xml` so prow indexes it. If an *enabled* suite
   produces no JUnit at all, treat it as a failure (force a non-zero exit) — a
   suite must never "pass" silently without results. In that path, dump the
   results tree (`find`, which is always present; `tree` often is not) to aid
   debugging and emit a *failing* JUnit so prow still ingests a result. Use
   `classname="osc.testsuites.<suite>"` in every JUnit testcase (skip, gate,
   no-results, and real results) so prow groups them consistently.
5. **Mirror the runner's exit code.** Capture the runner's `rc`, publish JUnit
   regardless, then `exit "${rc}"` (raised to non-zero if no results were
   produced). `best_effort` absorbs a non-zero exit so it won't block other
   suites, but the true result still surfaces.
6. **Register with `best_effort: true`** in the chain.
7. **Pre-flight tool verification.** After installing on-demand tools, run a loop
   asserting every required binary (`oc`, `kubectl`, `git`, suite-specific tools)
   is on `PATH`; fail immediately with a clear error if any is missing.
8. **Suites that need a cloud API client** (distinct from the cluster's
   peer-pods-secret) must source static credentials from `${CLUSTER_PROFILE_DIR}`
   (`osServicePrincipal.json` for Azure, `.awscred` for AWS). ci-operator mounts
   that directory in every phase including `post`. Never echo credential values or
   export them under names that would appear in `-x` traces. **Go test suites**
   must additionally export `HOME=/tmp`, `GOCACHE=/tmp/gocache`,
   `GOMODCACHE=/tmp/gomod`, and `GOFLAGS=-mod=mod` before running `go test` —
   the restricted SCC assigns an arbitrary non-root UID whose `$HOME` may be
   read-only, and test trees are not vendored.
9. Follow the general step-registry rules in [`../AGENTS.md`](../AGENTS.md):
   `set -euo pipefail` without `-x`, never echo credentials/URLs, pin+verify
   every download, choose the base image (`from:`) deliberately.

## Add a new suite (recipe)

1. Create `testsuites/<suite>/` with three files sharing the step-name prefix:
   `…-<suite>-ref.yaml`, `…-<suite>-commands.sh`, `…-<suite>-ref.metadata.json`
   (OWNERS). Copy from `kata-upstream/` and adapt.
2. In the ref: set `from:` per the tools you need (`src` if you need git),
   `cli: latest` for `oc`, resources/timeout/grace_period, and a
   `TESTS_<SUITE_NAME>_ENABLE` env (`default: "false"`) plus any suite
   parameters, all following the `TESTS_<SUITE_NAME>_<PARAMETER>` naming
   convention, each with `documentation`.
3. In `-commands.sh`: implement the enable-gate → gate → skipped-JUnit →
   provision tools (pinned+verified) → pre-flight verification loop → run →
   publish-JUnit (fail if none, with `find` dump + failing JUnit artifact) →
   mirror-rc flow (see kata-upstream walkthrough below). The gate block
   (convention 3b) goes right after the enable-gate.
4. Append the ref to `sandboxed-containers-operator-testsuites-chain.yaml` with
   `best_effort: true`.
5. To actually run it, set `TESTS_<SUITE_NAME>_ENABLE: "true"` on the desired
   test(s) in the configs — that's a config change; see the config AGENTS.md.
6. `make registry-metadata && make jobs` (checkconfig validates the registry and
   the image graph).

## Reference example: `kata-upstream`

Look at `kata-upstream/…-commands.sh` for the canonical structure:

- **Enable-gate first.** Default the env var in place and consume it directly —
  `TESTS_KATA_UPSTREAM_ENABLE="${TESTS_KATA_UPSTREAM_ENABLE:-false}"` (no parallel
  local); if not `"true"`, write `${ARTIFACT_DIR}/junit_kata_upstream_skip.xml` (a
  `<testsuite>` with a single `<skipped>` testcase) and `exit 0`.
- **Base image supplies git.** The ref uses `from: src` (git) + `cli: latest`
  (oc); `oc` is symlinked to `kubectl` because the runner calls `kubectl`. This
  is why the consuming configs need a `build_root` — see the config AGENTS.md
  graph-build coupling note.
- **Tools installed on-demand, pinned + verified.** `bats`, `yq`, `jq`,
  `envsubst` go into `/tmp/bin` via an `install_verified` helper
  (`curl` → `sha256sum -c` → `chmod +x`); `bats` (no release binary) is cloned at
  a pinned tag and its commit SHA checked. A final loop asserts every required
  tool is on `PATH` before proceeding.
- **Runner invocation is parameterized, not hard-coded.** Suite parameters come
  from env (`TESTS_KATA_UPSTREAM_PROFILE`, `TESTS_KATA_UPSTREAM_REPO`,
  `TESTS_KATA_UPSTREAM_REPO_REF`); empty values are omitted so the runner uses
  its own defaults. Logs print only sanitized metadata (profile + a "custom repo
  set" boolean), never the raw args, since a tests-repo URL may embed credentials.
- **Publish, fail if none, then mirror rc.** Copy `${RESULTS_DIR}/*/*.xml` to
  `${ARTIFACT_DIR}/junit_kata_upstream_*.xml`; if the enabled suite produced no
  JUnit, raise `rc` to non-zero; then `exit "${rc}"`.

New suites are free to differ in what they run, but should keep this skeleton:
enable-gate → skipped-JUnit → provision tools (pinned+verified) →
pre-flight verification loop → run (parameterized, sanitized logs) →
publish JUnit (fail if none: `find` dump + failing JUnit artifact) → mirror rc.

## Keeping This File Current

This file is living documentation — update it alongside any code change that
affects the information it describes. Examples of changes that require an
AGENTS.md update:

- A new suite is added to or removed from the testsuites chain (update the
  conventions list, the "add a new suite" recipe, and any cross-references to
  named suites). Current suites: `kata-upstream`, `osc`, `caa`.
- The gate mechanism changes (gate file path, which phase creates it, or what
  each suite checks).
- Convention rules evolve (JUnit naming, enable-gate env var shape, new required
  behaviours).
- The `kata-upstream` reference implementation is replaced or supplemented by a
  new canonical example.

The linked AGENTS.md files ([Step-registry AGENTS.md](../AGENTS.md),
[Config AGENTS.md](../../../config/openshift/sandboxed-containers-operator/AGENTS.md))
must be kept consistent — a change that touches the boundary between the two
scopes may need updates in both files.

## Related Documentation
- [Step-registry AGENTS.md](../AGENTS.md) — general ref/chain/workflow rules & runtime constraints
- [Config AGENTS.md](../../../config/openshift/sandboxed-containers-operator/AGENTS.md) — enabling a suite, pipeline images, graph-build coupling
- Repository-root `CLAUDE.md` — general repo structure
- `README.md` (this dir) — human-focused suite documentation
- [CI Operator Reference](https://steps.ci.openshift.org/ci-operator-reference) · [OpenShift CI Docs](https://docs.ci.openshift.org/)
