# RHWA supplied-FBC upgrade tests

All six OCP 5.0 FBC jobs use this step and the merged
`tier:upgrade-operator` tests from `openshift/rhwa-system-tests` main.
The source jobs build the operator checkout provided by Prow and run the same tests.

`SYSTEM_TESTS_REF` defaults to `main` for continuous validation of the current
tests. Set it to a branch, tag, or commit SHA to select a different test revision
or pin a reproducible run. The actual SHA is saved in `system-tests-commit.txt`.
An unavailable ref fails the checkout rather than falling back to `main`.

After checkout, refs with `deps-download` prepare the pinned modules and versioned
Ginkgo executable using `make deps-download ginkgo`, then run in readonly module
mode. Older refs use `go mod download` and `go mod verify` and keep their existing
build mode and tool installation, including vendoring where present. Preparation
needs access to the configured Go proxy and checksum service, or a complete cache
for the selected ref. The runner uses its writable temporary `GOMODCACHE` for
module source and `GOCACHE` for compiled packages; neither cache changes the
selected ref or disables checksum verification.

By default, each FBC job discovers the newest complete public main-branch RHWA
FBC build on Quay and reads its matching IDMS, operator version, and controller.
The chosen catalog digest and image expectations are recorded for that run.

For `FBC_CATALOG_MODE=provided`, the configured FBC is pinned to the public Konflux build
`sha256:e999cbe4fb3604d66ee71c9927827c2a88852b1456cb274ff1d673f1db9ce8fd`,
source commit `8c9972727d69b2abf9312ddc9e9b270aaf67597c`.
It was chosen using Or's "last build image" option; it is not asserted to be
identical to IIB 1225442.

The embedded IDMS is the exact
[`.tekton/images-mirror-set.yaml`](https://gitlab.cee.redhat.com/dragonfly/rhwa-fbc/-/blob/8c9972727d69b2abf9312ddc9e9b270aaf67597c/.tekton/images-mirror-set.yaml)
from that build's public source artifact. Controller digests in the six
`main__5.0.yaml` configs come from the catalog's 5.8.0 bundle related images.

To update the pinned build used by `provided` mode, update its digest and version in the ref, all six
controller digests and mirror repositories in the configs, and the embedded IDMS
together. Verify that the bundles and related images are available at those mirrors
before rehearsing.

## Catalog selection

`FBC_CATALOG_MODE=latest-build` is the default. It discovers the newest complete main-branch build in
`FBC_BUILD_REPOSITORY`. The [public Quay tag API](https://docs.projectquay.io/api_reference.html#listrepotags)
supplies commit-tagged builds;
PR builds, source archives, signatures, and incomplete image indexes are excluded.
The job pins the selected catalog's digest for the run and extracts the exact IDMS
from its public `.git` source artifact. It does not need VPN access to GitLab.

Use `provided` to keep the configured catalog, controller/version expectations,
and embedded IDMS unchanged instead of discovering a build.

Use `latest-stage` to resolve the current `FBC_STAGE_IMAGE` tag. This follows the
Dragonfly [manifest generator](https://gitlab.cee.redhat.com/dragonfly/rhwa-release-info/-/blob/2c27110/generate-install-manifests.sh):
it maps RHWA image pulls to
`registry.stage.redhat.io/workload-availability`. Stage registry credentials must
already be in the cluster pull secret; the job does not acquire or print them.

Both discovery modes read the selected operator/channel's unique head bundle,
derive its version and controller image, and verify a matching release mirror
before starting the Go test. Missing channels, ambiguous heads, unavailable source
artifacts, or missing image mirrors fail; there is no fallback to the provided build.
Exact version/image and configuration-preservation checks remain enabled. The
candidate must still be different from the installed GA baseline.

Artifacts include `candidate-images.json`, the selected `candidate-bundle.json`,
the operator's catalog metadata, and `idms.yaml`. Latest-build also records the
selected commit tag and publication timestamp in `fbc-build.json`.
Expected misses while trying older-version mirrors are retained in
`controller-mirror-probes.log` rather than printed as job failures.

Run the selection/parser failure fixtures with `bash hack/test-medik8s-fbc-discovery.sh`.
These mock registry/CLI calls; they do not install operators or access a cluster.

The runner image contains only test tools, not operator source. Registry credentials
are read from the cluster pull secret into a private file outside the artifact directory;
they are not printed. Catalog and exact controller-digest preflight runs before the
Go tests; the controller is inspected directly at its public release mirror.
The Go tests own IDMS application, MCP waiting, GA installation, upgrade, and cleanup.

SBR runs without storage; FAR runs without real fencing. NHC uses the proven
Prow oc-debug path, SNR reboots a worker, and NMO drains and recovers a worker.
Version/image and configuration-preservation checks remain enabled for every operator.

Local checks: CI config validation and job generation passed, as did shared-test
unit tests, six-suite dry runs, and the actual catalog/controller preflight for
each operator. All 15 candidate bundle/related-image digests were inspected at
their public mirrors. These are not cluster upgrade results; rehearsals are pending.
Full CI configuration and step-registry validation also passed with the resolver's
`--validate-only` mode, using a dummy kubeconfig and disabled container networking.

The exact runner Dockerfile was built locally using the resolved base-image digests.
Under UID 12345 and group 0, its Go toolchain built Ginkgo and all six suites;
`make test`, six label-filtered dry runs, and JUnit/Polarion report checks passed.
The actual shared shell passed all six public catalog/controller preflights and
suite/safety-setting checks. Synthetic-secret fixtures confirmed mode-0600 auth
outside artifacts; injected preflight/test failures preserved exit codes 1, 42,
and 43. The existing tests checkout was mounted read-only; no cluster was accessed.
