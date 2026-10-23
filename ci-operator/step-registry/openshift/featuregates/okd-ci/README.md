# OKD CI install feature gates

The IPI (including stable-initial and vSphere) and agent preparation refs apply
only when the **tested target** release metadata version identifies an OKD CI
payload. The timestamped `okd` / `okd-scos` versions are distinct from ART-derived
`okd-scos-nightly` versions. Image tags and job names are not sufficient: release
controllers share verification jobs and some output tags between CI and nightly.
See `hack/annotate.sh` and `core-services/release-controller/_releases/` for the
stream configuration. Nonmatching targets return before changing shared files.

For a matching target, existing feature selections are intentionally overridden.
The catalog comes from the **effective initial install payload**, not the upgrade
target. IPI uses `OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE` (including the custom
override); the upgrade workflow binds this to `release:initial`. Agent mirrors
the dev-scripts setup step's architecture-specific initial image selection.

Catalog extraction uses `oc adm release extract`, without `--included`: these
FeatureGate status catalogs are specially annotated and are not ordinary
included manifests. The helper selects the self-managed HA profile and payload
major version, accepting both older annotation-free catalogs and newer annotated
catalogs. It unions enabled and disabled names across fixed feature sets. The
installed cluster-config-operator's payload-pinned source determines whether
CustomNoUpgrade inherits Default: older consumers (including 4.15) require every
known gate explicitly, while modern consumers inherit Default-enabled gates and
explicitly enable all other known names. Only the verified direct-completion
and Default-merging dispatch forms are accepted; unknown forms fail closed.
This avoids both omitted old Default gates and duplicate modern status entries.
The selection records the source revision/hash and inheritance mode. The result
must have no disabled gates. Kubernetes
`AllAlpha` and `AllBeta` switches are never used.

Retained 4.13 payloads predate serialized catalogs. Only for those payloads, the
helper retrieves the vendored OpenShift API declarations at the exact kube API
server operator source commit recorded in the payload's image references. It
accepts the legacy literal declarations, unions all sets rather than only
Default, explicitly enables every name, records a source hash, and rejects
unrecognized expressions. It never consults API HEAD or a static current list.
Both pinned-source paths require HTTPS access to raw.githubusercontent.com. Missing catalogs,
unsupported source declarations and ambiguous catalogs fail closed.

IPI receives `featureSet` and (where supported) `featureGates` before
`create manifests`. The shared file `openshift_manifests_99_feature-gate.yaml`
then replaces the installer's `openshift/99_feature-gate.yaml` before ignition
generation, using the existing shared-manifest consumer. It is not a second
conflicting FeatureGate in the `manifests` directory.

Agent preparation stages a small Make include for the remote dev-scripts setup.
An additional `agent_create_cluster` prerequisite runs after `agent_configure`
and before image creation. It patches either install-config or the ZTP
AgentClusterInstall `agent-install.openshift.io/install-config-overrides`
annotation, preserving unrelated overrides, and stages the FeatureGate under
`${OCP_DIR}/openshift`. The pinned dev-scripts consumer at
`ff6edd3c7ca6fe018cc264e1c126a3aa75754e35` uses `ocp/${CLUSTER_NAME}` by default;
its agent path does **not** consume `ASSETS_EXTRA_FOLDER`. That variable is not
used as an agent delivery mechanism here.

Run `make test-okd-ci-featuregates` for catalog, scoping, initial selection,
legacy, IPI/stable-initial/vSphere workflow coverage, and agent configuration /
Make-hook ordering regression tests. These tests stub external payload reads
and cluster creation; they are not end-to-end cluster verification. Configuration
changes require `make ci-operator-config` followed by `make jobs`; registry changes
require `make registry-metadata`, `make ci-operator-checkconfig` and
`make validate-step-registry`.

CustomNoUpgrade intentionally preserves existing upgrade restrictions. Upgrade
jobs remain configured; this change does not force upgrades or suppress any
operator condition. Upgrade eligibility is a separate concern.
