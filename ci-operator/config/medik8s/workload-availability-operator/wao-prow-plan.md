# Plan: Prow installs the WAO operator (Goal 1) + e2e NMO test (Goal 2)

> Scope split per user direction: **Goal 1** has prow install the WAO operator via the standard
> optional-operators flow. **Goal 2** adds the e2e test to the same job: the repo's
> `make e2e-tests` target enables the NMO operand and runs the rhwa-system-tests
> `nmo-operator` suite against it.

## Status

- **Goal 1 — DONE** (shipped on branch `wao_poc`; the former `verify-wao-nmo-install` sanity
  step was later removed — `make e2e-tests` performs the same deployment wait as its first
  step).
- **Goal 2 — implemented in the working tree** (config runs `make e2e-tests`;
  `make update`/validation still pending — see §4 checklist).

---

## Goal 1 — prow installs the WAO operator (DONE)

### 1. As shipped (differs from the earlier sketch)

File: `ci-operator/config/medik8s/workload-availability-operator/medik8s-workload-availability-operator-wao__5.0.yaml`
(zz_generated_metadata: `org: medik8s, repo: workload-availability-operator, branch: wao,
variant: "5.0"`).

Deltas vs. the original plan sketch:

- Branch is **`wao`**, not `makefile` (the repo's default CI branch is `wao`; the plan's
  `makefile` branch idea was dropped).
- The operator image **is built by the job** (`images: dockerfile_path: Dockerfile`) with an
  `operator.substitutions` entry rewriting
  `quay.io/medik8s/workload-availability-operator:v0.1.0` to the pipeline-built image — instead
  of relying on a user-maintained quay `:dev` tag. The bundle (`bundle.Dockerfile`) is built and
  assembled into `ci-index` as in the oadp pattern.
- Job name: `install-wao-nmo-daily-aws` (cron `0 4 * * *`).
- `OO_TARGET_NAMESPACES: '!all'`, `OO_INSTALL_NAMESPACE: openshift-workload-availability`,
  `OO_CHANNEL: stable`, `OO_PACKAGE: workload-availability-operator`,
  `OO_INDEX: ci-index`, `BASE_DOMAIN: ocp-ci.medik8s-ci.devcluster.openshift.com`.
- `prowgen: enable_secrets_store_csi_driver: true`.

### 2. How the install works

- `workflow: optional-operators-ci-aws` = pre `ipi-aws-pre` → `optional-operators-subscribe`,
  post `ipi-aws-post` (step-registry: `optional-operators/ci/aws/`).
- `optional-operators-subscribe` creates the CatalogSource for `OO_INDEX`, OperatorGroup +
  Subscription for `OO_PACKAGE`/`OO_CHANNEL`, approves the InstallPlan and waits for CSV
  `Succeeded`. No scripted install, no nested podman, no ttl.sh.
- Job success == WAO installed with every operand Disabled (WAO creates the
  `WorkloadAvailabilityConfig` singleton `cluster` with all components off).

---

## Goal 2 — e2e test: `make e2e-tests` enables NMO and runs the suite

User decisions (2026-11-12): run the **nmo-operator feature** (not the wao-operator lifecycle
suite), add the step to the **existing daily job**, and run **all** nmo-operator specs —
label filter `!component:olm`, destructive specs included (the cluster is a fresh disposable
AWS cluster from `ipi-aws-pre`, so node drains are fine).

### 1. Design — the repo's make target is the test entry point

The test step is a single command. All enable/wait/run logic lives in the WAO repository
(`make e2e-tests` → `hack/e2e-tests.sh`), so prow and developers execute the identical code
path and the config carries no inline shell:

```yaml
test:
- as: e2e-nmo
  cli: latest
  commands: |
    make e2e-tests
  from: system-tests
  resources:
    requests:
      cpu: "2"
      memory: 4Gi
  timeout: 2h0m0s
```

What `make e2e-tests` does in CI (clone runner, the default):

1. Waits for `deployment/workload-availability-operator-controller-manager` — this replaced
   the former `verify-wao-nmo-install` step.
2. Patches the `WorkloadAvailabilityConfig/cluster` singleton (same merge patch
   rhwa-system-tests' `helpers.SetWAOComponents` sends):
   `oc patch workloadavailabilityconfig cluster --type=merge
   -p '{"spec":{"components":{"nodeMaintenance":{"enabled":true}}}}'`,
   polls `status.components[?(@.name=="nodeMaintenance")].phase` until `Available` (10s × 60,
   dumps cluster state on timeout) and waits for
   `deployment/node-maintenance-operator-controller-manager` (name from WAO's
   `internal/components/nmo.go`).
3. Runs `make run-tests` (ginkgo via rhwa-system-tests' `scripts/test-runner.sh`) from the
   rhwa-system-tests source. `GOCACHE` falls back to `/tmp` when `HOME` is unwritable.

The step container (`from: system-tests`, the `dockerfile_literal` passthrough of
`quay.io/medik8s/system-tests:wao`) is built from the rhwa-system-tests `wao` branch by that
repo's CI and carries **both the toolchain** (go, make, git, Go module cache) **and the test
source** under `/home/testuser`. CI points the make target at that baked-in source with
`E2E_SYSTEM_TESTS_DIR: /home/testuser`, so no github clone happens in prow — the same
`cd /home/testuser && make run-tests` the original inline step did, now reached through the
repo's make target. Locally the same variable accepts any checkout; unset, the target clones
branch `wao` into a tmp dir instead.

Environment (job-level `steps.env`, injected into the step container; every value matches the
Makefile default — kept explicit to document CI intent):

- `E2E_SYSTEM_TESTS_DIR: /home/testuser` — run the image's baked-in test source instead of
  cloning branch `wao` (no github dependency in prow; suite version = image build).
- `ECO_TEST_FEATURES: nmo-operator`
- `ECO_TEST_LABELS: "!component:olm"` — all specs, destructive included
- `ECO_TEST_VERBOSE` / `ECO_DUMP_FAILED_TESTS: "true"`
- `WORKLOAD_IMAGE: registry.access.redhat.com/ubi9/ubi-minimal:latest` — **required**; the
  suites panic at init without it. Matches the value prow's `medik8s-lib` step hardcodes as
  the single source of truth.
- `OO_*` / `BASE_DOMAIN`: install-flow variables, unchanged.

Step resources `cpu "2" / 4Gi`; `timeout: 2h0m0s` (the destructive specs drain and reboot
nodes, ~5–15 min each, so the earlier 1h was tight). No cleanup/disable at the end: the
cluster is deprovisioned by `ipi-aws-post`.

**Why `!component:olm`**: WAO installs operands from **manifests, not OLM**, so there is no
NMO ClusterServiceVersion on the cluster. The spec that requires a CSV ("Verify NMO CSV has
required annotations", `component:olm`) times out; excluded. (Setting `ECO_IS_DOWNSTREAM=false`
is not sufficient — `fetchActiveCSV()` runs before the skip.) Everything else in the
`nmo-operator` suite is expected to pass against a manifest-installed NMO — deployment,
`runAsNonRoot: true` and the ValidatingWebhookConfiguration are all present in WAO's rendered
operand manifests (`internal/operands/manifests/nmo/objects.yaml`).

### 2. Local reproduction

The same make target runs locally; `KUBECONFIG` is required on every invocation:

- `make e2e-tests` — clone runner on the host (tmp-dir clone of branch `wao`).
- `make e2e-ci-test` — image runner: `CONTAINER_TOOL` (default podman) runs
  `quay.io/medik8s/system-tests:wao` with the flattened kubeconfig mounted read-only and a
  host reports dir mounted at `/reports`. This is the closest local equivalent of the prow
  step's environment. **Not** usable by prow itself — the prow step already runs inside that
  image, which has no podman/docker, and nesting containers there would be wrong; prow
  reaches the same source via `E2E_SYSTEM_TESTS_DIR: /home/testuser` instead.
- Variables, defaults and examples are documented in `docs/e2e-tests.md` in the WAO repo
  (feature/label selection, `WORKLOAD_IMAGE`, `E2E_SYSTEM_TESTS_DIR` for iterating on test
  code, runner banners in the logs, etc.).

### 3. Rejected alternatives

- **wao-operator feature only** (RHWA-2040 operand lifecycle): enables/disables all six
  operands, no NMO functional coverage — user chose the nmo-operator path.
- **Both features in one job**: the lifecycle suite's BeforeAll requires every operand
  Disabled; would need careful sequencing (disable NMO again between steps). Deferred.
- **`make e2e-ci-test` as the prow command**: the image runner shells out to
  `CONTAINER_TOOL`, which the prow step container does not have — and it would nest the
  system-tests image inside itself, since the step already runs `from: system-tests`. Prow
  uses the baked-in source via `E2E_SYSTEM_TESTS_DIR` instead; `e2e-ci-test` stays the local
  reproduction of the prow environment.
- **Cloning rhwa-system-tests in prow** (the make target's default): works — git and egress
  are available in the step container (verified) — but adds a github dependency and a
  ~2–3 min clone of the vendored repo for no benefit, since the image already carries the
  `wao`-branch source. Superseded by `E2E_SYSTEM_TESTS_DIR: /home/testuser`; the clone
  remains the local default.
- **Inline enable/wait commands in the config** (the original Goal 2 sketch): superseded by
  `make e2e-tests` — one command in the config, one code path shared with developers.

### 4. Remaining checklist

1. `make update` (from repo root) — regenerates
   `ci-operator/jobs/medik8s/workload-availability-operator/...-periodics.yaml` and metadata.
2. `make checkconfig`.
3. Commit config + generated jobs together on `wao_poc`.
4. After merge, watch `periodic-ci-medik8s-workload-availability-operator-wao-5.0-install-wao-nmo-daily-aws`:
   - `e2e-nmo`: NMO operand reaches Available, all non-`component:olm` specs pass, JUnit XMLs
     in `$ARTIFACT_DIR/reports` (test-runner.sh also copies `*_testrun.xml` to `$SHARED_DIR`).
5. Optional follow-ups:
   - `post: [ref: medik8s-analyze-e2e-failure]` + `base_images: claude-ai-helpers` +
     `TEST_NAME`/`TEST_STEPS` env (AI failure analysis, as on the NMO daily).
   - Second step running the `wao-operator` lifecycle suite (requires all operands Disabled
     again first).
   - Move to a release-specific `__periodics.yaml` variant file once this feeds CI analytical
     tooling.
