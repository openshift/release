#!/bin/bash

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

function set_proxy () {
    if test -s "${SHARED_DIR}/proxy-conf.sh" ; then
        echo "Setting proxy configuration..."
        source "${SHARED_DIR}/proxy-conf.sh"
    else
        echo "No proxy settings found. Skipping proxy configuration..."
    fi
}

# Applicable for 'disconnected' env
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

# Applicable for 'disconnected' env
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

# Applicable for 'disconnected' env
function install_oc_mirror () {
    echo "[$(timestamp)] Installing the latest oc-mirror client..."
    run_command "curl -k -L -o oc-mirror.tar.gz https://mirror.openshift.com/pub/openshift-v4/$(uname -m)/clients/ocp/latest/oc-mirror.tar.gz"
    run_command "tar -xvzf oc-mirror.tar.gz && chmod +x ./oc-mirror && rm -f oc-mirror.tar.gz"
}

# Applicable for 'disconnected' env
function mirror_catalog_and_operator() {
    # Check if MUST_GATHER_IMAGE is set by the compute step
    if [[ -z "${MUST_GATHER_IMAGE:-}" ]]; then
        echo "ERROR: MUST_GATHER_IMAGE not set by compute step"
        exit 1
    fi
    
    if [[ -z "${BUNDLE_IMAGE:-}" ]]; then
        echo "ERROR: BUNDLE_IMAGE not set by compute step"
        exit 1
    fi

    if [[ -z "${OPERATOR_IMAGE:-}" ]]; then
        echo "ERROR: OPERATOR_IMAGE not set by compute step"
        exit 1
    fi

    echo "Using MUST_GATHER_IMAGE from compute step: ${MUST_GATHER_IMAGE}"
    echo "Using BUNDLE_IMAGE from compute step: ${BUNDLE_IMAGE}"
    echo "Using OPERATOR_IMAGE from compute step: ${OPERATOR_IMAGE}"
    
    # For disconnected environments, the images will be mirrored to the mirror registry
    # Set the mirrored image paths for disconnected environments, preserving the original tags
    MUST_GATHER_TAG=$(echo "${MUST_GATHER_IMAGE}" | sed 's/.*://')
    BUNDLE_TAG=$(echo "${BUNDLE_IMAGE}" | sed 's/.*://')
    OPERATOR_TAG=$(echo "${OPERATOR_IMAGE}" | sed 's/.*://')
    
    MIRRORED_MUST_GATHER_IMAGE="${MIRROR_REGISTRY_HOST}/redhat-user-workloads/kueue-operator-tenant/kueue-must-gather:${MUST_GATHER_TAG}"
    MIRRORED_BUNDLE_IMAGE="${MIRROR_REGISTRY_HOST}/redhat-user-workloads/kueue-operator-tenant/kueue-bundle-1-0:${BUNDLE_TAG}"
    MIRRORED_OPERATOR_IMAGE="${MIRROR_REGISTRY_HOST}/redhat-user-workloads/kueue-operator-tenant/kueue-operator-1-0:${OPERATOR_TAG}"
    
    echo "Mirrored MUST_GATHER_IMAGE for disconnected environment: ${MIRRORED_MUST_GATHER_IMAGE}"
    echo "Mirrored BUNDLE_IMAGE for disconnected environment: ${MIRRORED_BUNDLE_IMAGE}"
    echo "Mirrored OPERATOR_IMAGE for disconnected environment: ${MIRRORED_OPERATOR_IMAGE}"
    
    # Update the environment variables to use the mirrored images for disconnected environments
    # Replace the original values with mirrored paths
    sed -i "s|export MUST_GATHER_IMAGE=.*|export MUST_GATHER_IMAGE=${MIRRORED_MUST_GATHER_IMAGE}|" "${SHARED_DIR}/env"
    sed -i "s|export BUNDLE_IMAGE=.*|export BUNDLE_IMAGE=${MIRRORED_BUNDLE_IMAGE}|" "${SHARED_DIR}/env"
    sed -i "s|export OPERATOR_IMAGE=.*|export OPERATOR_IMAGE=${MIRRORED_OPERATOR_IMAGE}|" "${SHARED_DIR}/env"

    echo "[$(timestamp)] Creating ImageSetConfiguration for bundle and related images..."
    cat > ${TMP_DIR}/imageset.yaml << EOF
apiVersion: mirror.openshift.io/v2alpha1
kind: ImageSetConfiguration
mirror:
  additionalImages: # bundle and related images
  - name: ${BUNDLE_IMAGE}
  - name: ${MUST_GATHER_IMAGE}
  - name: ${OPERATOR_IMAGE}
  - name: quay.io/openshift/origin-oauth-proxy:4.14
  - name: registry.access.redhat.com/ubi9/ubi:9.4
EOF

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
        - ${MIRROR_REGISTRY_HOST}/redhat-user-workloads/kueue-operator-tenant/kueue-operator-1-0
      source: registry.redhat.io/kueue/kueue-rhel9-operator
    - mirrors:
        - ${MIRROR_REGISTRY_HOST}/redhat-user-workloads/kueue-operator-tenant/kueue-0-11
      source: registry.redhat.io/kueue/kueue-rhel9
EOF

oc apply -f - <<EOF
apiVersion: config.openshift.io/v1
kind: ImageTagMirrorSet
metadata:
  name: kueue-mirrorset
spec:
  imageTagMirrors:
    - mirrors:
        - ${MIRROR_REGISTRY_HOST}/redhat-user-workloads/kueue-operator-tenant/kueue-operator-1-0
      source: registry.redhat.io/kueue/kueue-rhel9-operator
    - mirrors:
        - ${MIRROR_REGISTRY_HOST}/redhat-user-workloads/kueue-operator-tenant/kueue-0-11
      source: registry.redhat.io/kueue/kueue-rhel9
EOF"

    echo "[$(timestamp)] Waiting for the MachineConfigPool to finish rollout..."
    oc wait mcp --all --for=condition=Updating --timeout=5m || true
    oc wait mcp --all --for=condition=Updated --timeout=20m || true
    echo "[$(timestamp)] Rollout progress completed"
}

# Applicable for 'disconnected' env
# Note: This is a temporary workaround to avoid the disruptive impact of the 'enable-qe-catalogsource-disconnected' step.
# As per current implementation, that step is called by every 'disconnected' cluster provisioning workflow that maintained by QE.
# Hence this function can be removed in future once above mentioned design is well refined.
function tmp_prune_distruptive_resource() {
    echo "Pruning the disruptive resources in pervious step 'enable-qe-catalogsource-disconnected'..."
    run_command "oc delete catalogsource qe-app-registry -n openshift-marketplace --ignore-not-found"
    run_command "oc delete imagecontentsourcepolicy image-policy-aosqe --ignore-not-found"
    run_command "oc delete imagedigestmirrorset image-policy-aosqe --ignore-not-found"

    echo "[$(timestamp)] Waiting for the MachineConfigPool to finish rollout..."
    oc wait mcp --all --for=condition=Updating --timeout=5m || true
    oc wait mcp --all --for=condition=Updated --timeout=20m || true
    echo "[$(timestamp)] Rollout progress completed"
}

echo "[$(timestamp)] Kueue operator catalog step - this step only handles image mirroring for disconnected environments"
echo "[$(timestamp)] The operator installation is done via operator-sdk run bundle, no catalog source needed"

timestamp
set_proxy

# Source the environment variables from the compute step
if test -s "${SHARED_DIR}/env" ; then
    echo "Sourcing environment variables from compute step..."
    source "${SHARED_DIR}/env"
fi

# Check if this is a disconnected environment that needs image mirroring
if test -s "${SHARED_DIR}/mirror_registry_url" ; then
    echo "[$(timestamp)] Disconnected environment detected - setting up image mirroring..."
    
    export TMP_DIR=/tmp/mirror-operators
    export OC_MIRROR_OUTPUT_DIR="${TMP_DIR}/working-dir/cluster-resources"
    export XDG_RUNTIME_DIR="${TMP_DIR}/run"
    mkdir -p "${XDG_RUNTIME_DIR}/containers"
    cd "$TMP_DIR"

    check_mirror_registry
    tmp_prune_distruptive_resource
    configure_host_pull_secret
    install_oc_mirror
    mirror_catalog_and_operator
    
    echo "[$(timestamp)] Image mirroring completed for disconnected environment"
else
    echo "[$(timestamp)] Connected environment detected - no image mirroring needed"
fi

# Create and label the namespace for the operator installation
echo "[$(timestamp)] Creating and labeling namespace for kueue operator..."
oc create namespace openshift-kueue-operator || true
oc label ns openshift-kueue-operator openshift.io/cluster-monitoring=true --overwrite

# workaround for OLM pod not running with restricted PSA (openshift-* namespace pattern)
oc label --overwrite ns openshift-kueue-operator security.openshift.io/scc.podSecurityLabelSync=true

# Verify namespace labels were applied correctly
echo "[$(timestamp)] Verifying namespace labels..."
oc get ns openshift-kueue-operator -o yaml | grep -E "(security|pod-security|cluster-monitoring)" || echo "Some labels may not be present"

# Specifically check for the OLM PSA workaround labels
if oc get ns openshift-kueue-operator -o jsonpath='{.metadata.labels.security\.openshift\.io/scc\.podSecurityLabelSync}' | grep -q "false"; then
    echo "✓ OLM PSA workaround applied: podSecurityLabelSync=false"
else
    echo "✗ WARNING: OLM PSA workaround not applied correctly"
fi

# Additional verification for disconnected environments
if test -s "${SHARED_DIR}/mirror_registry_url" ; then
    echo "[$(timestamp)] Verifying auth file was saved for disconnected environment..."
    if test -f "${SHARED_DIR}/containers-auth.json"; then
        echo "Auth file successfully saved to SHARED_DIR"
        echo "Auth file size: $(stat -c%s "${SHARED_DIR}/containers-auth.json") bytes"
    else
        echo "WARNING: Auth file not found in SHARED_DIR - this may cause authentication failures"
    fi
fi

# Final verification before completing catalog step
echo "[$(timestamp)] Performing final verification..."

# Check namespace exists and has required labels
if oc get ns openshift-kueue-operator >/dev/null 2>&1; then
    echo "✓ Namespace openshift-kueue-operator exists"
    
    # Check for required labels
    if oc get ns openshift-kueue-operator -o jsonpath='{.metadata.labels}' | grep -q "security.openshift.io/scc.podSecurityLabelSync.*false"; then
        echo "✓ Security label is present (podSecurityLabelSync=false)"
    else
        echo "✗ WARNING: Security label missing or incorrect - this may cause registry pod failures"
    fi
    
    if oc get ns openshift-kueue-operator -o jsonpath='{.metadata.labels}' | grep -q "pod-security.kubernetes.io/enforce.*privileged"; then
        echo "✓ Pod security enforcement is set to privileged"
    else
        echo "✗ WARNING: Pod security enforcement not set to privileged - this may cause registry pod failures"
    fi
else
    echo "✗ ERROR: Namespace openshift-kueue-operator does not exist"
    exit 1
fi

# Check bundle image environment variable
if [[ -n "${BUNDLE_IMAGE:-}" ]]; then
    echo "✓ BUNDLE_IMAGE is set: ${BUNDLE_IMAGE}"
else
    echo "✗ ERROR: BUNDLE_IMAGE is not set"
    exit 1
fi

echo "[$(timestamp)] Catalog step completed successfully!" 