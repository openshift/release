#!/bin/bash
set -o errexit -o nounset -o pipefail

: "${ARTIFACT_DIR:?ci-operator must provide ARTIFACT_DIR}"
case "$FBC_OPERATOR" in
  nhc|sbr|snr|far|mdr|nmo) ;;
  *) echo "Unsupported FBC_OPERATOR: $FBC_OPERATOR" >&2; exit 1 ;;
esac
exec > >(tee "$ARTIFACT_DIR/$FBC_OPERATOR-fbc-upgrade-tests.log") 2>&1

prepare_runtime() {
  echo '==> Read cluster pull secret for Red Hat registry access'
  local auth_dir=/tmp/fbc-registry-auth
  mkdir -p "$auth_dir"
  oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' |
    base64 --decode > "$auth_dir/auth.json"
  chmod 0600 "$auth_dir/auth.json"
  export REGISTRY_AUTH_FILE="$auth_dir/auth.json"

  # The test container runs as an arbitrary UID.
  export GOPATH=/tmp/fbc-go
  export GOMODCACHE="$GOPATH/pkg/mod"
  export GOCACHE=/tmp/fbc-go-build-cache
  mkdir -p "$GOMODCACHE" "$GOCACHE"
  go version
  skopeo --version
}

write_idms() {
  # Exact .tekton/images-mirror-set.yaml from the pinned catalog's source:
  # https://gitlab.cee.redhat.com/dragonfly/rhwa-fbc/-/blob/8c9972727d69b2abf9312ddc9e9b270aaf67597c/.tekton/images-mirror-set.yaml
  # Keep this and the catalog/controller digests in sync when updating the FBC.
  echo '==> Write release IDMS for all six operators'
  cat <<'EOF' > "$ARTIFACT_DIR/idms.yaml"
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: rhwa-fbc-fips-image-mirror-set
spec:
  imageDigestMirrors:
    - mirrors:
        - quay.io/redhat-user-workloads/rhwa-tenant/node-healthcheck-operator/nhc-operator-0-10
        - quay.io/redhat-user-workloads/rhwa-tenant/node-healthcheck-operator/nhc-operator-0-11
        - quay.io/redhat-user-workloads/rhwa-tenant/node-healthcheck-operator/nhc-operator-0-12
        - quay.io/redhat-user-workloads/rhwa-tenant/node-healthcheck-operator/nhc-operator-5-8
      source: registry.redhat.io/workload-availability/node-healthcheck-rhel9-operator
    - mirrors:
        - quay.io/redhat-user-workloads/rhwa-tenant/node-healthcheck-operator/nhc-bundle-0-10
        - quay.io/redhat-user-workloads/rhwa-tenant/node-healthcheck-operator/nhc-bundle-0-11
        - quay.io/redhat-user-workloads/rhwa-tenant/node-healthcheck-operator/nhc-bundle-0-12
        - quay.io/redhat-user-workloads/rhwa-tenant/node-healthcheck-operator/nhc-bundle-5-8
      source: registry.redhat.io/workload-availability/node-healthcheck-operator-bundle
    - mirrors:
        - quay.io/redhat-user-workloads/rhwa-tenant/node-healthcheck-operator/nhc-console-0-10
        - quay.io/redhat-user-workloads/rhwa-tenant/node-healthcheck-operator/nhc-console-0-11
        - quay.io/redhat-user-workloads/rhwa-tenant/node-healthcheck-operator/nhc-console-0-12
        - quay.io/redhat-user-workloads/rhwa-tenant/node-healthcheck-operator/nhc-console-5-8
      source: registry.redhat.io/workload-availability/node-remediation-console-rhel9
    - mirrors:
        - quay.io/redhat-user-workloads/rhwa-tenant/node-healthcheck-operator/nhc-must-gather-0-10
        - quay.io/redhat-user-workloads/rhwa-tenant/node-healthcheck-operator/nhc-must-gather-0-11
        - quay.io/redhat-user-workloads/rhwa-tenant/node-healthcheck-operator/nhc-must-gather-0-12
        - quay.io/redhat-user-workloads/rhwa-tenant/node-healthcheck-operator/nhc-must-gather-5-8
      source: registry.redhat.io/workload-availability/node-healthcheck-must-gather-rhel9
    - mirrors:
        - quay.io/redhat-user-workloads/rhwa-tenant/self-node-remediation/snr-operator-0-11
        - quay.io/redhat-user-workloads/rhwa-tenant/self-node-remediation/snr-operator-0-12
        - quay.io/redhat-user-workloads/rhwa-tenant/self-node-remediation/snr-operator-0-13
        - quay.io/redhat-user-workloads/rhwa-tenant/self-node-remediation/snr-operator-5-8
      source: registry.redhat.io/workload-availability/self-node-remediation-rhel9-operator
    - mirrors:
        - quay.io/redhat-user-workloads/rhwa-tenant/self-node-remediation/snr-bundle-0-11
        - quay.io/redhat-user-workloads/rhwa-tenant/self-node-remediation/snr-bundle-0-12
        - quay.io/redhat-user-workloads/rhwa-tenant/self-node-remediation/snr-bundle-0-13
        - quay.io/redhat-user-workloads/rhwa-tenant/self-node-remediation/snr-bundle-5-8
      source: registry.redhat.io/workload-availability/self-node-remediation-operator-bundle
    - mirrors:
        - quay.io/redhat-user-workloads/rhwa-tenant/fence-agents-remediation/far-operator-0-6
        - quay.io/redhat-user-workloads/rhwa-tenant/fence-agents-remediation/far-operator-0-7
        - quay.io/redhat-user-workloads/rhwa-tenant/fence-agents-remediation/far-operator-0-8
        - quay.io/redhat-user-workloads/rhwa-tenant/fence-agents-remediation/far-operator-5-8
      source: registry.redhat.io/workload-availability/fence-agents-remediation-rhel9-operator
    - mirrors:
        - quay.io/redhat-user-workloads/rhwa-tenant/fence-agents-remediation/far-bundle-0-6
        - quay.io/redhat-user-workloads/rhwa-tenant/fence-agents-remediation/far-bundle-0-7
        - quay.io/redhat-user-workloads/rhwa-tenant/fence-agents-remediation/far-bundle-0-8
        - quay.io/redhat-user-workloads/rhwa-tenant/fence-agents-remediation/far-bundle-5-8
      source: registry.redhat.io/workload-availability/fence-agents-remediation-operator-bundle
    - mirrors:
        - quay.io/redhat-user-workloads/rhwa-tenant/machine-deletion-remediation/mdr-operator-0-5
        - quay.io/redhat-user-workloads/rhwa-tenant/machine-deletion-remediation/mdr-operator-0-6
        - quay.io/redhat-user-workloads/rhwa-tenant/machine-deletion-remediation/mdr-operator-0-7
        - quay.io/redhat-user-workloads/rhwa-tenant/machine-deletion-remediation/mdr-operator-5-8
      source: registry.redhat.io/workload-availability/machine-deletion-remediation-rhel9-operator
    - mirrors:
        - quay.io/redhat-user-workloads/rhwa-tenant/machine-deletion-remediation/mdr-bundle-0-5
        - quay.io/redhat-user-workloads/rhwa-tenant/machine-deletion-remediation/mdr-bundle-0-6
        - quay.io/redhat-user-workloads/rhwa-tenant/machine-deletion-remediation/mdr-bundle-0-7
        - quay.io/redhat-user-workloads/rhwa-tenant/machine-deletion-remediation/mdr-bundle-5-8
      source: registry.redhat.io/workload-availability/machine-deletion-remediation-operator-bundle
    - mirrors:
        - quay.io/redhat-user-workloads/rhwa-tenant/node-maintenance-operator/nmo-operator-5-5
        - quay.io/redhat-user-workloads/rhwa-tenant/node-maintenance-operator/nmo-operator-5-6
        - quay.io/redhat-user-workloads/rhwa-tenant/node-maintenance-operator/nmo-operator-5-7
        - quay.io/redhat-user-workloads/rhwa-tenant/node-maintenance-operator/nmo-operator-5-8
      source: registry.redhat.io/workload-availability/node-maintenance-rhel9-operator
    - mirrors:
        - quay.io/redhat-user-workloads/rhwa-tenant/node-maintenance-operator/nmo-bundle-5-5
        - quay.io/redhat-user-workloads/rhwa-tenant/node-maintenance-operator/nmo-bundle-5-6
        - quay.io/redhat-user-workloads/rhwa-tenant/node-maintenance-operator/nmo-bundle-5-7
        - quay.io/redhat-user-workloads/rhwa-tenant/node-maintenance-operator/nmo-bundle-5-8
      source: registry.redhat.io/workload-availability/node-maintenance-operator-bundle
    - mirrors:
        - quay.io/redhat-user-workloads/rhwa-tenant/storage-based-remediation/sbr-agent-0-3
        - quay.io/redhat-user-workloads/rhwa-tenant/storage-based-remediation/sbr-agent-5-8
      source: registry.redhat.io/workload-availability/storage-based-remediation-agent-rhel9
    - mirrors:
        - quay.io/redhat-user-workloads/rhwa-tenant/storage-based-remediation/sbr-operator-0-3
        - quay.io/redhat-user-workloads/rhwa-tenant/storage-based-remediation/sbr-operator-5-8
      source: registry.redhat.io/workload-availability/storage-based-remediation-rhel9-operator
    - mirrors:
        - quay.io/redhat-user-workloads/rhwa-tenant/storage-based-remediation/sbr-bundle-0-3
        - quay.io/redhat-user-workloads/rhwa-tenant/storage-based-remediation/sbr-bundle-5-8
      source: registry.redhat.io/workload-availability/storage-based-remediation-operator-bundle
EOF
}

prepare_candidate() {
  write_idms

  # Use the supplied FBC; this job does not build operator or bundle images.
  local prefix="${FBC_OPERATOR^^}_FBC"
  export "${prefix}_CATALOG_IMAGE=$FBC_CATALOG_IMAGE"
  export "${prefix}_CANDIDATE_VERSION=$FBC_CANDIDATE_VERSION"
  export "${prefix}_CANDIDATE_IMAGE=$FBC_CANDIDATE_IMAGE"
  export "${prefix}_CHANNEL=$FBC_CHANNEL"
  export "${prefix}_IDMS_PATH=$ARTIFACT_DIR/idms.yaml"

  echo '==> Verify the supplied catalog is pullable before running tests'
  skopeo inspect --no-creds --no-tags --format '{{.Digest}}' "docker://$FBC_CATALOG_IMAGE"

  echo '==> Verify the exact controller digest at its public release mirror'
  local digest="${FBC_CANDIDATE_IMAGE##*@}"
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]
  test -n "$FBC_CANDIDATE_MIRROR"
  grep -Fq -- "- $FBC_CANDIDATE_MIRROR" "$ARTIFACT_DIR/idms.yaml"
  skopeo inspect --no-creds --no-tags --format '{{.Digest}}' \
    "docker://$FBC_CANDIDATE_MIRROR@$digest"
}

checkout_system_tests() {
  echo '==> Check out openshift/rhwa-system-tests main'
  git clone --depth=1 --branch main \
    https://github.com/openshift/rhwa-system-tests.git /tmp/system-tests
  git -C /tmp/system-tests show --no-patch --format=fuller HEAD
  git -C /tmp/system-tests rev-parse HEAD > "$ARTIFACT_DIR/system-tests-commit.txt"
}

print_run_config() {
  echo "Operator: $FBC_OPERATOR"
  echo "Candidate catalog: $FBC_CATALOG_IMAGE"
  echo "Candidate version: $FBC_CANDIDATE_VERSION"
  echo "Candidate controller: $FBC_CANDIDATE_IMAGE"
  echo "Controller mirror: $FBC_CANDIDATE_MIRROR"
  echo "Channel: $FBC_CHANNEL"
  echo "IDMS: $ARTIFACT_DIR/idms.yaml"
}

run_upgrade_test() {
  export ECO_TEST_FEATURES="$FBC_OPERATOR-operator"
  export ECO_TEST_LABELS=tier:upgrade-operator
  export ECO_TEST_VERBOSE=true
  export WORKLOAD_IMAGE=registry.access.redhat.com/ubi9/ubi-minimal:latest

  # Match the proven source jobs' operator-specific safety settings.
  case "$FBC_OPERATOR" in
    nhc) export MEDIK8S_KUBELET_STOP_OCDEBUG=true ;;
    sbr) export SBR_FBC_REMEDIATION=false; unset SBR_STORAGE_CLASS ;;
    far) export FAR_FBC_REMEDIATION=false ;;
  esac

  echo '==> Start system-tests tier: upgrade-operator'
  export ECO_REPORTS_DUMP_DIR="$ARTIFACT_DIR/upgrade-operator"
  mkdir -p "$ECO_REPORTS_DUMP_DIR"
  make -C /tmp/system-tests run-tests 2>&1 | tee "$ECO_REPORTS_DUMP_DIR/run.log"
}

main() {
  prepare_runtime
  prepare_candidate
  checkout_system_tests
  print_run_config
  run_upgrade_test
}

main
