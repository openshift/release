# RHWA source-build upgrade tests

All six OCP 5.0 source jobs use this step. Each config selects `SOURCE_OPERATOR`
and builds its existing runner image under the common alias
`source-upgrade-test-runner`. Runner contents and SDK pins are unchanged;
the runner still contains the operator checkout selected by Prow, not a clone
of main or a hardcoded development PR.

The shared script keeps the same sequence as the previous inline scripts:

1. Prepare registry authentication, writable Go caches, and rootless Podman.
2. Read the source version and latest released GA bundle version.
3. Build/push operator, bundle, and FBC with `make dev-olm-catalog-push`.
4. Resolve immutable image digests and validate the candidate bundle/version.
5. Run `openshift/rhwa-system-tests` main's `tier:upgrade-operator` test.

Operator-specific inputs stay explicit: NHC supplies pinned console/must-gather
images and checks its Go version against the Makefile; SBR builds a separate
agent image. FAR's runner retains SDK v1.42.3, while the other five retain
v1.42.2. Every source checkout's SDK pin is checked before building.

The same upgrade/configuration-preservation tests are used as in the supplied-FBC
jobs, but source images are directly pullable from ttl.sh, so no release IDMS
is applied. Existing safety settings are preserved: SBR needs no ODF and does
not perform storage-backed remediation; FAR does not fence machines; NHC uses
oc-debug for worker disruption.

Credentials stay in a mode-0600 temporary file outside artifacts and are never
printed. Source/test commits, candidate images, and test output are retained
under `ARTIFACT_DIR`. Test failures propagate through the logging pipeline.
