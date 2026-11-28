#!/usr/bin/env bash

set -e
set -u
set -o pipefail

function fail() {
    echo "ERROR: $*" >&2
    exit 1
}

# Mirror the ART build into the CI mirror registry for the disconnected e2e job.
#
# The Konflux variant mirrors a Quay bundle plus the three CSV images rewired
# onto the Konflux tenant paths. The ART variant mirrors what the FBC points at
# instead: the bundle and its relatedImages at registry.stage.redhat.io (ART
# publishes pre-release digests there only). oc-mirror keeps the source
# namespace, so the images land under <mirror>/kueue/* and the ImageDigestMirrorSet
# rewrites registry.redhat.io/kueue/* pulls onto those paths.
#
# kueue-operator-disconnected-run-sdk is reused unchanged: it installs
# ${BUNDLE_IMAGE} from the mirror registry.
#
# Like the Konflux variant, this step never contacts the cluster API: the mirror
# policies are written to ${SHARED_DIR} and applied by run-sdk.

function timestamp() {
    date -u --rfc-3339=seconds
}

function run_command() {
    local cmd="$1"
    echo "Running Command: ${cmd}"
    if ! eval "${cmd}"; then
        fail "command failed: ${cmd}"
    fi
}

function check_mirror_registry () {
    if test -s "${SHARED_DIR}/mirror_registry_url" ; then
        MIRROR_REGISTRY_HOST=$(head -n 1 "${SHARED_DIR}/mirror_registry_url")
        export MIRROR_REGISTRY_HOST
        echo "Using mirror registry: ${MIRROR_REGISTRY_HOST}"
    else
        echo "This is not a disconnected environment as no mirror registry url set. Skipping rest of steps..."
        exit 0
    fi
}

function configure_host_pull_secret () {
    echo "Retrieving the redhat, redhat stage, and mirror registries pull secrets from shared credentials..."
    redhat_registry_path="/var/run/vault/mirror-registry/registry_redhat.json"
    redhat_auth_user=$(jq -r '.user' $redhat_registry_path)
    redhat_auth_password=$(jq -r '.password' $redhat_registry_path)
    redhat_registry_auth=$(echo -n "$redhat_auth_user:$redhat_auth_password" | base64 -w 0)

    stage_registry_path="/var/run/vault/mirror-registry/registry_stage.json"
    stage_auth_user=$(jq -r '.user' $stage_registry_path)
    stage_auth_password=$(jq -r '.password' $stage_registry_path)
    stage_registry_auth=$(echo -n "$stage_auth_user:$stage_auth_password" | base64 -w 0)

    mirror_registry_path="/var/run/vault/mirror-registry/registry_creds"
    mirror_registry_auth=$(head -n 1 "$mirror_registry_path" | base64 -w 0)

    echo "Building Podman auth from the cluster profile pull secret (no cluster API required)..."
    jq --argjson a "{\"registry.redhat.io\": {\"auth\": \"$redhat_registry_auth\"}, \"registry.stage.redhat.io\": {\"auth\": \"$stage_registry_auth\"}, \"${MIRROR_REGISTRY_HOST}\": {\"auth\": \"$mirror_registry_auth\"}}" '.auths |= . + $a' "${CLUSTER_PROFILE_DIR}/pull-secret" > ${XDG_RUNTIME_DIR}/containers/auth.json

    # Save auth file to SHARED_DIR for reuse by other steps
    echo "Saving auth file to SHARED_DIR for reuse by other steps..."
    cp "${XDG_RUNTIME_DIR}/containers/auth.json" "${SHARED_DIR}/containers-auth.json"
}

function install_oc_mirror () {
    CGWURL="https://openshift-mirror-list.ci-systems.workers.dev/pub/cgw"
    ARCH=$(uname -m)
    case ${ARCH} in
        x86_64) ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
    esac
    echo "[$(timestamp)] Installing the latest oc-mirror client..."
    run_command "curl -fL -o oc-mirror.tar.gz ${CGWURL}/oc-mirror/latest/oc-mirror-rhel9-linux-${ARCH}.tar.gz"
    run_command "tar -xvzf oc-mirror.tar.gz && chmod +x ./oc-mirror && rm -f oc-mirror.tar.gz"
}

# Mirror the source ref onto the mirror registry, preserving the kueue namespace.
# A registry.stage.redhat.io/kueue/<image>@sha256:… source is mirrored by
# oc-mirror to <mirror>/kueue/<image>@sha256:… (the registry host is dropped).
function mirrored_ref () {
    local src="$1" repo name digest
    repo="${src%%@*}"
    digest="${src##*@}"
    if [[ "${repo}" != */kueue/* || "${digest}" != sha256:* ]]; then
        echo "ERROR: unexpected ART image reference ${src}" >&2
        return 1
    fi
    name="${repo##*/}"
    echo "${MIRROR_REGISTRY_HOST}/kueue/${name}@${digest}"
}

function mirror_catalog_and_operator() {
    local name
    for name in BUNDLE_SOURCE_IMAGE OPERATOR_SOURCE_IMAGE OPERAND_SOURCE_IMAGE MUST_GATHER_SOURCE_IMAGE; do
        if [[ -z "${!name:-}" ]]; then
            fail "${name} was not provided by the compute-art step"
        fi
    done

    BUNDLE_MIRRORED_IMAGE=$(mirrored_ref "${BUNDLE_SOURCE_IMAGE}") || fail "unusable BUNDLE_SOURCE_IMAGE=${BUNDLE_SOURCE_IMAGE}"
    MUST_GATHER_MIRRORED_IMAGE=$(mirrored_ref "${MUST_GATHER_SOURCE_IMAGE}") || fail "unusable MUST_GATHER_SOURCE_IMAGE=${MUST_GATHER_SOURCE_IMAGE}"
    echo "Mirrored BUNDLE_IMAGE for disconnected environment: ${BUNDLE_MIRRORED_IMAGE}"
    echo "Mirrored MUST_GATHER_IMAGE for disconnected environment: ${MUST_GATHER_MIRRORED_IMAGE}"

    echo "export BUNDLE_IMAGE=${BUNDLE_MIRRORED_IMAGE}" >> "${SHARED_DIR}/env"
    echo "export MUST_GATHER_IMAGE=${MUST_GATHER_MIRRORED_IMAGE}" >> "${SHARED_DIR}/env"

    echo "[$(timestamp)] Creating ImageSetConfiguration for the ART bundle and related images..."
    cat > ${TMP_DIR}/imageset.yaml << EOF
apiVersion: mirror.openshift.io/v2alpha1
kind: ImageSetConfiguration
mirror:
  additionalImages:
  - name: ${BUNDLE_SOURCE_IMAGE}
  - name: ${OPERATOR_SOURCE_IMAGE}
  - name: ${OPERAND_SOURCE_IMAGE}
  - name: ${MUST_GATHER_SOURCE_IMAGE}
  - name: quay.io/openshift/origin-oauth-proxy:4.14
  - name: registry.access.redhat.com/ubi9/ubi:9.4
  - name: registry.access.redhat.com/ubi9/ubi-minimal:latest
  - name: docker.io/library/busybox:1.36.0
  - name: quay.io/prometheus/busybox:latest
EOF

    echo "[$(timestamp)] Final ImageSetConfiguration:"
    cat ${TMP_DIR}/imageset.yaml

    echo "[$(timestamp)] Mirroring the images to the mirror registry..."
    run_command "./oc-mirror --v2 --config=${TMP_DIR}/imageset.yaml --workspace=file://${TMP_DIR} docker://${MIRROR_REGISTRY_HOST} --log-level=info --retry-times=5 --dest-tls-verify=false"

    # Preserve the complete opm manifest list; oc-mirror's platform filtering
    # edits it and fails when preserving the original digests. --insecure is
    # required because the bastion mirror registry serves plain HTTP, and
    # `oc image mirror` has a single flag covering both source and destination
    # (unlike oc-mirror's --src-tls-verify/--dest-tls-verify split).
    oc image mirror --keep-manifest-list=true --filter-by-os='.*' --insecure=true \
        --registry-config="${XDG_RUNTIME_DIR}/containers/auth.json" \
        "quay.io/operator-framework/opm:latest=${MIRROR_REGISTRY_HOST}/operator-framework/opm:latest"

    # operator-sdk serves the bundle from the mirror path, but the CSV it ships
    # references the component images at registry.redhat.io by digest.
    OPERATOR_NAME=$(basename "${OPERATOR_SOURCE_IMAGE%%@*}")
    OPERAND_NAME=$(basename "${OPERAND_SOURCE_IMAGE%%@*}")
    MUST_GATHER_NAME=$(basename "${MUST_GATHER_SOURCE_IMAGE%%@*}")

    echo "[$(timestamp)] Saving image mirror policies to SHARED_DIR (applied by run_sdk)..."
    cat > "${SHARED_DIR}/kueue-idms.yaml" <<EOF
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: kueue-digest-mirrorset
spec:
  imageDigestMirrors:
    - mirrors:
        - ${MIRROR_REGISTRY_HOST}/kueue/${OPERATOR_NAME}
      source: registry.redhat.io/kueue/${OPERATOR_NAME}
    - mirrors:
        - ${MIRROR_REGISTRY_HOST}/kueue/${OPERAND_NAME}
      source: registry.redhat.io/kueue/${OPERAND_NAME}
    - mirrors:
        - ${MIRROR_REGISTRY_HOST}/kueue/${MUST_GATHER_NAME}
      source: registry.redhat.io/kueue/${MUST_GATHER_NAME}
EOF
    cat > "${SHARED_DIR}/kueue-itms.yaml" <<EOF
apiVersion: config.openshift.io/v1
kind: ImageTagMirrorSet
metadata:
  name: kueue-mirrorset
spec:
  imageTagMirrors:
    - mirrors:
        - ${MIRROR_REGISTRY_HOST}/library/busybox
      source: docker.io/library/busybox
    - mirrors:
        - ${MIRROR_REGISTRY_HOST}/ubi9/ubi
      source: registry.access.redhat.com/ubi9/ubi
    - mirrors:
        - ${MIRROR_REGISTRY_HOST}/ubi9/ubi-minimal
      source: registry.access.redhat.com/ubi9/ubi-minimal
    - mirrors:
        - ${MIRROR_REGISTRY_HOST}/operator-framework/opm
      source: quay.io/operator-framework/opm
    - mirrors:
        - ${MIRROR_REGISTRY_HOST}/prometheus/busybox
      source: quay.io/prometheus/busybox
EOF
}

timestamp

# Source the environment variables from the compute step.
if test -s "${SHARED_DIR}/env" ; then
    echo "Sourcing environment variables from compute step..."
    source "${SHARED_DIR}/env"
fi

# NOTE: this step intentionally does not contact the cluster API.
# Image mirror policies and namespace setup are saved to SHARED_DIR and
# applied by run_sdk, so build-farm DNS outages cannot affect this step.

export TMP_DIR=/tmp/mirror-operators
export OC_MIRROR_OUTPUT_DIR="${TMP_DIR}/working-dir/cluster-resources"
export XDG_RUNTIME_DIR="${TMP_DIR}/run"
mkdir -p "${XDG_RUNTIME_DIR}/containers"
cd "$TMP_DIR"

check_mirror_registry
configure_host_pull_secret
install_oc_mirror
echo "[$(timestamp)] === Mirroring the ART bundle and related images ==="
mirror_catalog_and_operator
echo "[$(timestamp)] Image mirroring completed for disconnected environment"

echo "[$(timestamp)] ART mirror step completed successfully (cluster API not required)."
