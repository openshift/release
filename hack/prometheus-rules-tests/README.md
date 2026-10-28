# Prometheus alert rule unit tests

`promtool test rules` unit tests for the generated user-workload-monitoring
alert rules in
`clusters/core-ci/openshift-user-workload-monitoring/mixins/prometheus_out/ci-alerts_prometheusrule.yaml`.

These guard the resolve-side hysteresis (`keep_firing_for`), window, and
expression-correctness behavior of the alerts so regressions (e.g. an alert that
silently never fires) are caught — the mixins pipeline only checks that the
generated YAML matches jsonnet, never the PromQL semantics.

They live under `hack/` (not `clusters/`) on purpose: files under `clusters/`
are treated as deployable manifests by the cluster-manifest-verifier presubmit,
and these are promtool test fixtures, not manifests.

## Running

From the repo root (needs a container engine — podman/docker):

```bash
make validate-prometheus-rules
```

Or directly, inside any image with `promtool` on PATH:

```bash
hack/validate-prometheus-rules.sh .
```

`hack/validate-prometheus-rules.sh` renders a native rules file from the
PrometheusRule CR (`spec:` dedented) into `.rendered-rules.yaml` here
(git-ignored), runs `promtool check rules` on it, then
`promtool test rules ./*_test.yaml`.

## Adding a test

Create `<name>_test.yaml` here with `rule_files: [.rendered-rules.yaml]` and the
standard promtool [unit-test schema](https://prometheus.io/docs/prometheus/latest/configuration/unit_testing_rules/).
`exp_annotations` must match the rendered message exactly (templates expanded).

## Enforcing in CI (proposed)

There is no promtool presubmit yet. To enforce these on every PR, add a
hand-maintained presubmit alongside `generated-dashboards` in
`ci-operator/jobs/openshift/release/openshift-release-main-presubmits.yaml`
(one of the infra jobs maintained there directly), e.g.:

```yaml
- agent: kubernetes
  always_run: false
  branches:
  - ^main$
  - ^main-
  cluster: build02
  context: ci/prow/prometheus-rules-tests
  decorate: true
  decoration_config:
    sparse_checkout_files:
    - ./clusters/core-ci/openshift-user-workload-monitoring/mixins/prometheus_out/ci-alerts_prometheusrule.yaml
    - ./hack/prometheus-rules-tests
    - ./hack/validate-prometheus-rules.sh
  labels:
    pj-rehearse.openshift.io/can-be-rehearsed: "true"
  name: pull-ci-openshift-release-main-prometheus-rules-tests
  rerun_command: /test prometheus-rules-tests
  run_if_changed: ^(clusters/core-ci/openshift-user-workload-monitoring/mixins/prometheus_out/ci-alerts_prometheusrule\.yaml|hack/prometheus-rules-tests/.*|hack/validate-prometheus-rules\.sh)$
  spec:
    containers:
    - args:
      - .
      command:
      - hack/validate-prometheus-rules.sh
      image: quay.io/prometheus/prometheus:v2.53.5
      imagePullPolicy: Always
      name: ""
      resources:
        requests:
          cpu: 10m
  trigger: ((?m)^/test prometheus-rules-tests,?(\s+|$))
```

Pin `image:` to a `promtool`-containing image available to the CI cluster
(the official `quay.io/prometheus/prometheus` tag here is a starting point;
swap for an openshift-mirrored image if required).
