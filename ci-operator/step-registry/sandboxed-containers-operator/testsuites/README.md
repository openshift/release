# OSC POST-phase test-suite chain

`sandboxed-containers-operator-testsuites` is a **`post`-phase chain** that runs one
or more independent test suites after the main `test:` phase of the OSC
(sandboxed-containers-operator) e2e workflows. Each suite is a step in the chain,
gated by an enable variable and marked `best_effort: true` so that a
failing / skipped / erroring suite **never blocks** the other suites or the
remaining post steps (`cucushift-installer-wait`, must-gather, deprovision).

## Background & design intent (KATA-5727)

The goal is to run **multiple test suites, potentially sourced from different
repositories, after the main test setup succeeds** — without any one suite blocking
the others. That work is split across two engines:

- **Orchestration engine — [`openshift/release`](https://github.com/openshift/release)**
  (this repo). Holds the Prow/ci-operator definitions and step registry. All of the
  wiring for this feature lives here.
- **Test execution engine — [`openshift-tests-private`](https://github.com/openshift/openshift-tests-private)
  (OTP)**. Provides the automated suites and the `openshift-extended-test` step that
  the `test:` phase runs. It **must remain unchanged** so that the existing test
  setup still completes as before — this feature adds to `post`, it does not touch
  `test:`.

Design decisions that follow from that intent:

- **The new chain runs first in `post`.** The `test:` phase and its
  `openshift-extended-test` step are left exactly as they are; the extra suites are
  layered on afterward so a failing suite can never interfere with the primary test
  run's setup or result.
- **Suites do not block each other on pass / error / skip.** This is the whole point
  — one repository's suite failing must not prevent another's from running. Achieved
  with `best_effort` in `post` (see below).
- **Explicit, per-suite enable gating** via `TESTS_<SUITE_NAME>_ENABLE`, so a job opts
  into exactly the suites it wants and everything else skips gracefully. Every ProwJob
  variable for a suite follows the `TESTS_<SUITE_NAME>_<PARAMETER>` convention.
- **Every suite emits standard Prow artifacts + JUnit**, so results show up in
  Spyglass whether the suite ran, was skipped, or failed.

**Scope** is deliberately limited to `ci-operator/**/sandboxed-containers-operator/`.

`kata-upstream` is the first **real** suite in the chain (the upstream Kata
Containers e2e tests). `skeleton2` is a DEMO/template suite that, when enabled,
always succeeds; it is disabled by default (see below) and serves as the copy-paste
pattern new suites follow.

## Why POST (and not `test:`)

`best_effort` is **not honored in the `test:` phase** — a failing test-phase step
aborts the rest of the phase regardless of `best_effort`. Continue-on-failure only
works in the `post:` phase, and only when the referencing workflow sets
`allow_best_effort_post_steps: true`. Therefore the multi-suite chain lives entirely
in `post`.

Non-blocking behaviour requires **both**:

1. Workflow: `steps.allow_best_effort_post_steps: true`, and
2. Each suite step in the chain: `best_effort: true`.

> Non-blocking is not the same as "job stays green". A `best_effort` step that fails
> still marks the **overall job red** — it just doesn't stop the steps that follow it.
> To keep a job green you would additionally exit 0 or use `optional_on_success`.

## Layout

```
testsuites/
├── README.md                                              (this file)
├── sandboxed-containers-operator-testsuites-chain.yaml    (the POST chain)
├── kata-upstream/                                         (real suite -- upstream Kata e2e)
│   ├── ...-kata-upstream-ref.yaml
│   └── ...-kata-upstream-commands.sh
└── skeleton2/                                             (DEMO/template suite -- always succeeds)
    ├── ...-skeleton2-ref.yaml
    └── ...-skeleton2-commands.sh
```

## Enable convention

Each suite is gated by `TESTS_<SUITE_NAME>_ENABLE`, **skip-by-default**:

- `== "true"`  → the suite runs and logs its result.
- `"false"` or unset → the suite logs the value and exits 0 (graceful skip).

Every suite writes a JUnit file to `${ARTIFACT_DIR}/junit_<name>.xml` in **both**
the run and skip paths, so Prow always ingests a result.

## The `skeleton2` step is a DEMO — disabled by default

`skeleton2` is a **demonstration/template** suite, not a real test. It exists to
prove the non-blocking wiring end-to-end and to serve as a copy-paste template for
real suites. It is **disabled by default** (`TESTS_SKELETON2_ENABLE` defaults to
`"false"` in its ref), so in normal jobs it just logs the value and exits 0.

| Step        | When enabled (`TESTS_SKELETON2_ENABLE=true`)          | JUnit                         |
|-------------|-------------------------------------------------------|-------------------------------|
| `skeleton2` | **Always succeeds** (exit 0)                          | passing `junit_skeleton2.xml` |

Because `skeleton2` runs after `kata-upstream` in the chain and always passes, it
also demonstrates the key behaviour: a later suite still runs and passes even when
an earlier suite failed, and the post phase continues through must-gather and
deprovision. Because it is a demo, do **not** enable it on production periodics.

## Wiring into a workflow

The chain is already wired into the azure, aro, and aws OSC e2e workflows
(`e2e/{azure,aro,aws}/...-workflow.yaml`):

```yaml
workflow:
  steps:
    allow_best_effort_post_steps: true    # required for non-blocking post
    ...
    post:
    - chain: sandboxed-containers-operator-testsuites   # runs first in post
    - ref: cucushift-installer-wait
      ...
```

## Adding a real suite

1. Create a step directory under `testsuites/` (e.g. `testsuites/<suite>/`) with a
   `...-<suite>-ref.yaml` (env `TESTS_<SUITE_NAME>_ENABLE`, default `"false"`;
   name all suite parameters `TESTS_<SUITE_NAME>_<PARAMETER>`) and a
   `...-<suite>-commands.sh` (default `set -euo pipefail`; write
   `${ARTIFACT_DIR}/junit_<suite>.xml` in both the run and skip paths).
2. Append the ref to `sandboxed-containers-operator-testsuites-chain.yaml` with
   `best_effort: true`.
3. Run `make update` (generates the `*.metadata.json` files) and validate with the
   ci-operator config resolver.
4. Enable it on the desired job(s) by setting `TESTS_<SUITE_NAME>_ENABLE: "true"` in
   that job's `steps.env`.

The registry naming rule requires each `as:` name to equal its directory path
relative to `step-registry/` with `/` replaced by `-` (e.g.
`testsuites/<suite>` → `sandboxed-containers-operator-testsuites-<suite>`).
