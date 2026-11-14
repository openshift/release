# OKD CI install feature gates

The IPI preparation ref (including stable-initial and vSphere) applies
only when the **tested target** release metadata version identifies an OKD CI
payload. The timestamped `okd` / `okd-scos` versions are distinct from ART-derived
`okd-scos-nightly` versions. Image tags and job names are not sufficient: release
controllers share verification jobs and some output tags between CI and nightly.
See `hack/annotate.sh` and `core-services/release-controller/_releases/` for the
stream configuration. Nonmatching targets return before changing shared files.

For a matching target, existing feature selections are intentionally overridden.
The catalog comes from the **effective initial install payload**, not the upgrade
target. IPI uses `OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE` (including the custom
override); the upgrade workflow binds this to `release:initial`.

Catalog extraction uses `oc adm release extract`, without `--included`: these
FeatureGate status catalogs are specially annotated and are not ordinary
included manifests. The helper selects the self-managed HA profile and payload
major version, accepting both older annotation-free catalogs and newer annotated
catalogs. It unions enabled and disabled names across fixed feature sets. The
helper explicitly enables every name in that union under CustomNoUpgrade,
with an empty disabled list, independently of whether a consumer inherits Default.
No source code is downloaded or parsed, and Kubernetes `AllAlpha` and `AllBeta`
switches are never used. Missing or incompatible catalogs fail clearly before
changing install settings. Older payloads without serialized FeatureGate catalogs
(including retained 4.13 payloads) are unsupported and fail closed; there is no
legacy source fallback or API HEAD/static gate list.

External operations make at most three attempts with 1- and 2-second backoff.
Each release-info attempt has a 120-second timeout; each extraction attempt has
a 600-second timeout and a fresh temporary directory. Only failed commands and
timeouts are retried, not malformed metadata or incompatible catalogs.
Exhausted attempts abort preparation before changing install settings.

IPI receives `featureSet` and `featureGates` before
`create manifests`. The shared file `openshift_manifests_99_feature-gate.yaml`
then replaces the installer's `openshift/99_feature-gate.yaml` before ignition
generation, using the existing shared-manifest consumer. It is not a second
conflicting FeatureGate in the `manifests` directory.

Agent installs are intentionally excluded. Their workflows and dev-scripts
provisioner do not run this preparation ref or consume its staged artifacts.

Run `make test-okd-ci-featuregates` for catalog, scoping, initial selection,
missing catalogs, IPI/stable-initial/vSphere workflow coverage, and negative dev-scripts /
agent workflow isolation regression tests. These tests stub external payload reads
and cluster creation; they are not end-to-end cluster verification. Configuration
changes require `make ci-operator-config` followed by `make jobs`; registry changes
require `make registry-metadata`, `make ci-operator-checkconfig` and
`make validate-step-registry`.

CustomNoUpgrade intentionally preserves existing upgrade restrictions. Upgrade
jobs remain configured; this change does not force upgrades or suppress any
operator condition. Upgrade eligibility is a separate concern.
