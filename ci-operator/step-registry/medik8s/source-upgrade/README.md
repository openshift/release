# RHWA source-build upgrade tests

All six OCP 5.0 source jobs use this step. Each config selects `SOURCE_OPERATOR`
and builds its existing runner image under the common alias
`source-upgrade-test-runner`. SDK pins are unchanged;
the runner still contains the operator checkout selected by Prow, not a clone
of main or a hardcoded development PR.

The shared script keeps the same sequence as the previous inline scripts:

1. Prepare registry authentication, writable Go caches, and rootless Podman.
2. Read the source version and latest released GA bundle version.
3. Build/push operator, bundle, and FBC with `make dev-olm-catalog-push`.
4. Resolve immutable image digests and validate the candidate bundle/version.
5. Run the selected `openshift/rhwa-system-tests` ref's `tier:upgrade-operator` test.

`SYSTEM_TESTS_REF` defaults to `main` for continuous validation of the current
tests. Set it to a branch, tag, or commit SHA to select a different test revision
or pin a reproducible run. The actual SHA is saved in `system-tests-commit.txt`.
An unavailable ref fails the checkout rather than falling back to `main`.

Each source runner copies Mike Farah yq v4.53.2 from its version-tagged image.
The script uses it to read the candidate CSV's `spec.version` and requires an
exact match with the source version. Missing, empty, or duplicate version entries fail.

Operator-specific inputs stay explicit: NHC supplies pinned console/must-gather
images and checks its Go version against the Makefile; SBR builds a separate
agent image. The runner's SDK must match the operator Makefile's pin;
the script checks this before building.

Build-tool images use explicit version tags for readability. Catalog/controller
test inputs and NHC related images still use digests as required by the shared
test and build-input checks.

NHC's console and must-gather defaults come from the `relatedImages` of
`node-healthcheck-operator.v5.8.0` in catalog `sha256:e999cbe4fb3604d66ee71c9927827c2a88852b1456cb274ff1d673f1db9ce8fd`.
They use the exact digests at the public Quay mirrors listed in the
[release IDMS](https://gitlab.cee.redhat.com/dragonfly/rhwa-fbc/-/blob/8c9972727d69b2abf9312ddc9e9b270aaf67597c/.tekton/images-mirror-set.yaml),
so no IDMS is needed for those direct pullspecs. These inputs affect only the
candidate bundle; GA is installed from `redhat-operators` with its own images.

The same upgrade/configuration-preservation tests are used as in the supplied-FBC
jobs, but source images are directly pullable from ttl.sh, so no release IDMS
is applied. Existing safety settings are preserved: SBR does not require ODF and
does not perform storage-based remediation; FAR does not fence machines.
The NHC test uses oc-debug to stop a worker's kubelet. NHC detects the unhealthy
worker and requests remediation through SNR, whose agent reboots the worker.

Credentials stay in a mode-0600 temporary file outside artifacts and are never
printed. Source/test commits, candidate images, and test output are retained
under `ARTIFACT_DIR`. Test failures propagate through the logging pipeline.
