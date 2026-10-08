# RHWA supplied-FBC upgrade tests

All six OCP 5.0 FBC jobs use this step and the merged
`tier:upgrade-operator` tests from `openshift/rhwa-system-tests` main.
The source jobs build the operator checkout provided by Prow and run the same tests.

The FBC is pinned to the public Konflux build
`sha256:e999cbe4fb3604d66ee71c9927827c2a88852b1456cb274ff1d673f1db9ce8fd`,
source commit `8c9972727d69b2abf9312ddc9e9b270aaf67597c`.
It was chosen using Or's "last build image" option; it is not asserted to be
identical to IIB 1225442.

The embedded IDMS is the exact
[`.tekton/images-mirror-set.yaml`](https://gitlab.cee.redhat.com/dragonfly/rhwa-fbc/-/blob/8c9972727d69b2abf9312ddc9e9b270aaf67597c/.tekton/images-mirror-set.yaml)
from that build's public source artifact. Controller digests in the six
`main__5.0.yaml` configs come from the catalog's 5.8.0 bundle related images.

To update the supplied FBC, update its digest and version in the ref, all six
controller digests and mirror repositories in the configs, and the embedded IDMS
together. Verify that the bundles and related images are available at those mirrors
before rehearsing.

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
