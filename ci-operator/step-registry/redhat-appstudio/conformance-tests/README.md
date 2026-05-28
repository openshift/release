# redhat-appstudio-conformance-tests

Runs Konflux conformance tests from the
[konflux-ci/konflux-ci](https://github.com/konflux-ci/konflux-ci) repository against a
pre-installed Konflux instance.

This step is designed to run **after** `konflux-ci-install-konflux`, which handles the
full cluster setup.

## What it does

1. **Selects a GitHub account** with the highest remaining API rate limit.
2. **Clones `konflux-ci/konflux-ci`** at the `main` branch (or a specific ref via
   Gangway override).
3. **Deploys test resources** via `deploy-test-resources.sh`, which creates:
   - Tenant namespaces (`user-ns1`, `user-ns2`)
   - Kueue `LocalQueue` for pipeline scheduling
   - `ServiceAccounts` and `RoleBindings` via Kyverno policies
4. **Verifies the tenant namespace** has a working `LocalQueue`.
5. **Creates the `konflux-cli` namespace** with the `setup-release` ConfigMap.
6. **Runs Go conformance tests** using Ginkgo v2 with configurable label filters.

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `GINKGO_LABEL_FILTER` | `upstream-konflux` | Ginkgo label filter for selecting which tests to run |
| `KONFLUX_REPO` | `konflux-ci/konflux-ci` | GitHub org/repo to clone tests from |
| `KONFLUX_REF` | `main` | Git ref (branch, tag, or SHA) to checkout |
| `GINKGO_TEST_TIMEOUT` | `30m` | Timeout for the Go test runner |

## Gangway override

When triggered via Gangway with `MULTISTAGE_PARAM_OVERRIDE_OPERATOR_IMAGE`, the image tag
is extracted and used as `KONFLUX_REF`. This allows testing specific commits or releases
without changing the CI config.

## Credentials

Same credential bundle as `konflux-ci-install-konflux` — the `konflux-ci-secrets-new` secret
mounted at `/usr/local/konflux-ci-secrets-new/redhat-appstudio-qe/`. Only the following keys
are used by this step:

| Key | Purpose |
|-----|---------|
| `github_accounts` | GitHub API access for cloning repos and running tests |
| `default-quay-org-token` | Quay org token exported for test pipelines |
| `quay-token` | Docker config for Quay registry auth |

## Usage

Pair with the install step in a multi-stage test:

```yaml
tests:
- as: appstudio-e2e-tests
  cluster_claim:
    architecture: amd64
    cloud: aws
    owner: konflux
    product: ocp
    timeout: 1h0m0s
    version: "4.18"
  steps:
    test:
    - ref: konflux-ci-install-konflux
    - ref: redhat-appstudio-conformance-tests
    workflow: redhat-appstudio-claim-failure-analysis
```

To run a different label filter (e.g. only build tests):

```yaml
steps:
  test:
  - ref: konflux-ci-install-konflux
  - as: build-conformance
    from: e2e-test-runner
    commands: |
      export GINKGO_LABEL_FILTER="build"
    ref: redhat-appstudio-conformance-tests
```

## Timeout

Default timeout is **2 hours**. Most conformance suites complete in 20-40 minutes, but
the extended timeout accommodates the full upstream-konflux label filter which includes
longer-running integration and release pipeline tests.
