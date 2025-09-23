#!/usr/bin/env bash

set -e
set -u
set -o pipefail

function timestamp() {
    date -u --rfc-3339=seconds
}

function run_command() {
    local cmd="$1"
    echo "Running Command: ${cmd}"
    eval "${cmd}"
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
    
    echo "Appending the pull secrets to Podman auth configuration file '${XDG_RUNTIME_DIR}/containers/auth.json'..."
    oc extract secret/pull-secret -n openshift-config --confirm --to ${TMP_DIR}
    jq --argjson a "{\"registry.redhat.io\": {\"auth\": \"$redhat_registry_auth\"}, \"registry.stage.redhat.io\": {\"auth\": \"$stage_registry_auth\"}, \"${MIRROR_REGISTRY_HOST}\": {\"auth\": \"$mirror_registry_auth\"}}" '.auths |= . + $a' "${TMP_DIR}/.dockerconfigjson" > ${XDG_RUNTIME_DIR}/containers/auth.json
    
    # Save auth file to SHARED_DIR for reuse by other steps
    echo "Saving auth file to SHARED_DIR for reuse by other steps..."
    cp "${XDG_RUNTIME_DIR}/containers/auth.json" "${SHARED_DIR}/containers-auth.json"
}

function install_oc_mirror () {
    echo "[$(timestamp)] Installing the latest oc-mirror client..."
    run_command "curl -k -L -o oc-mirror.tar.gz https://mirror.openshift.com/pub/openshift-v4/$(uname -m)/clients/ocp/latest/oc-mirror.tar.gz"
    run_command "tar -xvzf oc-mirror.tar.gz && chmod +x ./oc-mirror && rm -f oc-mirror.tar.gz"
}

function mirror_catalog_and_operator() {
    
    if [[ -z "${BUNDLE_IMAGE:-}" ]]; then
        echo "ERROR: BUNDLE_IMAGE not set by compute step"
        exit 1
    fi

    echo "Using BUNDLE_IMAGE from compute step: ${BUNDLE_IMAGE}"
    
    # For disconnected environments, the images will be mirrored to the mirror registry
    # Set the mirrored image paths for disconnected environments, preserving the original tags
    BUNDLE_TAG=$(echo "${BUNDLE_IMAGE}" | sed 's/.*://')
    MUST_GATHER_DIGEST=$(echo "${MUST_GATHER_IMAGE_FROM_CSV}" | sed 's/.*@/@/')

    # Extract the digest from the CSV operator image and construct the Quay equivalent.
    OPERATOR_DIGEST=$(echo "${OPERATOR_IMAGE_FROM_CSV}" | sed 's/.*@/@/')
    OPERAND_DIGEST=$(echo "${OPERAND_IMAGE_FROM_CSV}" | sed 's/.*@/@/')
    QUAY_OPERATOR_IMAGE="quay.io/redhat-user-workloads/kueue-operator-tenant/${OPERATOR_COMPONENT:-kueue-operator-1-1}${OPERATOR_DIGEST}"
    QUAY_OPERAND_IMAGE="quay.io/redhat-user-workloads/kueue-operator-tenant/${OPERAND_COMPONENT:-kueue-0-12}${OPERAND_DIGEST}"
    QUAY_MUST_GATHER_IMAGE="quay.io/redhat-user-workloads/kueue-operator-tenant/${MUST_GATHER_COMPONENT:-kueue-must-gather-1-0}${MUST_GATHER_DIGEST}"


    MIRRORED_BUNDLE_IMAGE="${MIRROR_REGISTRY_HOST}/redhat-user-workloads/kueue-operator-tenant/${BUNDLE_COMPONENT:-kueue-bundle-1-1}:${BUNDLE_TAG}"
    MIRRORED_MUST_GATHER_IMAGE="${MIRROR_REGISTRY_HOST}/redhat-user-workloads/kueue-operator-tenant/${MUST_GATHER_COMPONENT:-kueue-must-gather-1-0}${MUST_GATHER_DIGEST}"
    
    echo "Mirrored BUNDLE_IMAGE for disconnected environment: ${MIRRORED_BUNDLE_IMAGE}"
    echo "Mirrored MUST_GATHER_IMAGE for disconnected environment: ${MIRRORED_MUST_GATHER_IMAGE}"
    
    # Update the environment variables to use the mirrored images for disconnected environments
    # Replace the original values with mirrored paths
    sed -i "s|export BUNDLE_IMAGE=.*|export BUNDLE_IMAGE=${MIRRORED_BUNDLE_IMAGE}|" "${SHARED_DIR}/env"
    echo "export MUST_GATHER_IMAGE=${MIRRORED_MUST_GATHER_IMAGE}" >> "${SHARED_DIR}/env"

    echo "[$(timestamp)] Creating ImageSetConfiguration for bundle, related images, AND exact CSV references..."
    cat > ${TMP_DIR}/imageset.yaml << EOF
apiVersion: mirror.openshift.io/v2alpha1
kind: ImageSetConfiguration
mirror:
  additionalImages: # bundle and related images
  - name: ${BUNDLE_IMAGE}
  - name: quay.io/openshift/origin-oauth-proxy:4.14
  - name: registry.access.redhat.com/ubi9/ubi:9.4
  - name: quay.io/operator-framework/opm:latest
  - name: docker.io/library/busybox:1.36.0
  - name: ${QUAY_MUST_GATHER_IMAGE}
  # Mirror Quay operator andoperand images since registry.redhat.io version may not be available during release.
  - name: ${QUAY_OPERATOR_IMAGE}
  - name: ${QUAY_OPERAND_IMAGE}
EOF

    echo "[$(timestamp)] Final ImageSetConfiguration with CSV images:"
    cat ${TMP_DIR}/imageset.yaml

    echo "[$(timestamp)] Mirroring the images to the mirror registry..."
    run_command "./oc-mirror --v2 --config=${TMP_DIR}/imageset.yaml --workspace=file://${TMP_DIR} docker://${MIRROR_REGISTRY_HOST} --log-level=info --retry-times=5 --src-tls-verify=false --dest-tls-verify=false"

    echo "[$(timestamp)] Setting up image mirroring for disconnected environment..."
    run_command "oc apply -f - <<EOF
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: kueue-digest-mirrorset
spec:
  imageDigestMirrors:
    - mirrors:
        - ${MIRROR_REGISTRY_HOST}/redhat-user-workloads/kueue-operator-tenant/${OPERATOR_COMPONENT}
      source: registry.redhat.io/kueue/kueue-rhel9-operator
    - mirrors:
        - ${MIRROR_REGISTRY_HOST}/redhat-user-workloads/kueue-operator-tenant/${OPERAND_COMPONENT}
      source: registry.redhat.io/kueue/kueue-rhel9
    - mirrors:
        - ${MIRROR_REGISTRY_HOST}/redhat-user-workloads/kueue-operator-tenant/${MUST_GATHER_COMPONENT}
      source: registry.redhat.io/kueue/kueue-must-gather-rhel9

EOF

oc apply -f - <<EOF
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
        - ${MIRROR_REGISTRY_HOST}/operator-framework/opm
      source: quay.io/operator-framework/opm

EOF"

    echo "[$(timestamp)] Waiting for the MachineConfigPool to finish rollout..."
    oc wait mcp --all --for=condition=Updating --timeout=5m || true
    oc wait mcp --all --for=condition=Updated --timeout=20m || true
    echo "[$(timestamp)] Rollout progress completed"
}

timestamp

# Source the environment variables from the compute step.
if test -s "${SHARED_DIR}/env" ; then
    echo "Sourcing environment variables from compute step..."
    source "${SHARED_DIR}/env"
fi

export TMP_DIR=/tmp/mirror-operators
export OC_MIRROR_OUTPUT_DIR="${TMP_DIR}/working-dir/cluster-resources"
export XDG_RUNTIME_DIR="${TMP_DIR}/run"
mkdir -p "${XDG_RUNTIME_DIR}/containers"
cd "$TMP_DIR"

check_mirror_registry
configure_host_pull_secret
install_oc_mirror
echo "[$(timestamp)] === Mirroring catalog and operator images ==="  
mirror_catalog_and_operator
echo "[$(timestamp)] Image mirroring completed for disconnected environment"


# Create and label the namespace for the operator installation.
echo "[$(timestamp)] Creating and labeling namespace for kueue operator..."
oc create namespace openshift-kueue-operator || true
oc label ns openshift-kueue-operator openshift.io/cluster-monitoring=true --overwrite

# workaround for OLM pod not running with restricted PSA (openshift-* namespace pattern)
oc label --overwrite ns openshift-kueue-operator security.openshift.io/scc.podSecurityLabelSync=true

echo "[$(timestamp)] Catalog step completed successfully!"
