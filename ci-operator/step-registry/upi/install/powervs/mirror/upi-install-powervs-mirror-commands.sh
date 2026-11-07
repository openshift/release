#!/bin/bash

# OCPSTRAT-1808: Sparse Manifest Mirroring for Power/Intel (p-px disconnected job)
#
# This step runs after upi-install-powervs-cluster has provisioned the bastion.
# It:
#   1. Installs a local container registry (quay-lite / registry:2) on the bastion
#   2. Mirrors the nightly multi-arch release image, filtering to ppc64le + amd64
#      (sparse manifest mirroring — avoids pulling all architectures)
#   3. Writes mirror_registry_url and idms-registry-mirror.yaml to SHARED_DIR
#      so subsequent steps and the cluster install can consume the mirror

set -o nounset
set -o pipefail

IBMCLOUD_HOME=/tmp/ibmcloud
export IBMCLOUD_HOME

PATH=${PATH}:/tmp:"${IBMCLOUD_HOME}/ocp-install-dir"
export PATH

# ── Bastion connection info written by upi-install-powervs-cluster ─────────────
BASTION_PUBLIC_IP=$(< "${SHARED_DIR}/BASTION_PUBLIC_IP")
BASTION_PRIVATE_IP=$(< "${SHARED_DIR}/BASTION_PRIVATE_IP")
SSH_KEY="${IBMCLOUD_HOME}/ocp4-upi-powervs/data/id_rsa"

# Use the host key scanned by upi-install-powervs-cluster (stored in SHARED_DIR)
# to verify the bastion's identity on every SSH/SCP call.
BASTION_KNOWN_HOSTS="${SHARED_DIR}/bastion_known_hosts"
if [ ! -s "${BASTION_KNOWN_HOSTS}" ]; then
    echo "[ERROR] ${BASTION_KNOWN_HOSTS} is missing or empty." \
         "upi-install-powervs-cluster must run before this step."
    exit 1
fi

SSH_OPTS="-o StrictHostKeyChecking=yes -o UserKnownHostsFile=${BASTION_KNOWN_HOSTS} -o ConnectTimeout=60 -i ${SSH_KEY}"

echo "Bastion Public IP  : ${BASTION_PUBLIC_IP}"
echo "Bastion Private IP : ${BASTION_PRIVATE_IP}"

# ── Helper: run a command on the bastion with retries ──────────────────────────
function bastion_exec() {
    local max_retries=${1}
    local cmd=${2}
    local attempt=1
    while [ "${attempt}" -le "${max_retries}" ]; do
        echo "[bastion_exec attempt ${attempt}/${max_retries}] ${cmd}"
        # shellcheck disable=SC2086
        if ssh ${SSH_OPTS} root@"${BASTION_PUBLIC_IP}" "${cmd}"; then
            return 0
        fi
        attempt=$(( attempt + 1 ))
        sleep 30
    done
    echo "[ERROR] command failed after ${max_retries} attempts: ${cmd}"
    return 1
}

# ── Helper: copy a local file to the bastion ──────────────────────────────────
function bastion_copy() {
    local local_path=${1}
    local remote_path=${2}
    # shellcheck disable=SC2086
    scp ${SSH_OPTS} "${local_path}" root@"${BASTION_PUBLIC_IP}":"${remote_path}"
}

# ── 1. Ensure oc is available on the bastion ──────────────────────────────────
function ensure_oc_on_bastion() {
    echo "=== Checking oc availability on bastion ==="
    if bastion_exec 1 "which oc && oc version --client"; then
        echo "oc is already installed on bastion"
        return 0
    fi

    echo "Copying local oc binary to bastion"
    OC_BIN=$(which oc)
    bastion_copy "${OC_BIN}" /usr/local/bin/oc
    bastion_exec 3 "chmod +x /usr/local/bin/oc && oc version --client"
}

# ── 2. Start a local Docker registry on the bastion ───────────────────────────
# Uses podman (available on RHEL/CentOS bastion) to run the registry:2 image.
function setup_local_registry() {
    echo "=== Setting up local mirror registry on bastion ==="

    # Build the registry address used both inside and outside the bastion
    MIRROR_REGISTRY_HOST="${BASTION_PRIVATE_IP}:${MIRROR_REGISTRY_PORT}"
    export MIRROR_REGISTRY_HOST

    # Save for subsequent steps
    echo "${MIRROR_REGISTRY_HOST}" > "${SHARED_DIR}/mirror_registry_url"
    echo "Mirror registry URL: ${MIRROR_REGISTRY_HOST}"

    # Pull registry:2 image and start it (idempotent)
    bastion_exec 3 "
        podman rm -f local-mirror-registry 2>/dev/null || true
        podman pull docker.io/library/registry:2
        podman run -d --name local-mirror-registry \
            -p ${MIRROR_REGISTRY_PORT}:5000 \
            --restart=always \
            -v /var/lib/registry:/var/lib/registry \
            docker.io/library/registry:2
    "

    # Allow the registry to come up
    sleep 10
    bastion_exec 5 "curl -sf http://localhost:${MIRROR_REGISTRY_PORT}/v2/_catalog"
    echo "Local registry is up at ${MIRROR_REGISTRY_HOST}"

    # Configure containerd/podman on bastion to allow insecure access
    bastion_exec 3 "
        mkdir -p /etc/containers/registries.conf.d
        cat > /etc/containers/registries.conf.d/mirror-registry.conf <<'REGEOF'
[[registry]]
location = \"${MIRROR_REGISTRY_HOST}\"
insecure = true
REGEOF
    "
}

# ── 3. Prepare pull-secret with mirror registry credentials ───────────────────
function prepare_pull_secret() {
    echo "=== Preparing pull secret with mirror registry entry ==="

    # The local registry runs without auth; we add a dummy auth entry so
    # oc adm release mirror accepts it.
    DUMMY_AUTH=$(echo -n "user:password" | base64 -w0)

    [[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
    set +x

    jq --argjson entry \
        "{\"${MIRROR_REGISTRY_HOST}\": {\"auth\": \"${DUMMY_AUTH}\", \"email\": \"noreply@example.com\"}}" \
        '.auths |= . + $entry' \
        "${CLUSTER_PROFILE_DIR}/pull-secret" > /tmp/mirror-pull-secret.json

    if [[ "${WAS_TRACING}" == true ]]; then set -x; fi

    # Copy to bastion for use during mirror
    bastion_copy /tmp/mirror-pull-secret.json /tmp/mirror-pull-secret.json
    echo "Pull secret prepared"
}

# ── 4. Mirror the release image (sparse manifest: ppc64le + amd64 only) ───────
function mirror_release_image() {
    echo "=== Mirroring release image with sparse manifest filtering ==="
    echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE: ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
    echo "SPARSE_MANIFEST_ARCHES: ${SPARSE_MANIFEST_ARCHES}"

    # Authenticate CI registry on the bastion so it can pull the source image
    unset KUBECONFIG
    oc registry login

    # Get the readable version tag for target image naming
    READABLE_VERSION=$(oc adm release info "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" \
        -o jsonpath='{.metadata.version}')
    echo "Readable version: ${READABLE_VERSION}"

    TARGET_REPO="${MIRROR_REGISTRY_HOST}/ocp4/openshift4"
    TARGET_IMAGE="${TARGET_REPO}:${READABLE_VERSION}"

    echo "Target repository : ${TARGET_REPO}"
    echo "Target image      : ${TARGET_IMAGE}"

    # Save the mirrored release image reference for the cluster install step
    echo "${TARGET_IMAGE}" > "${SHARED_DIR}/MIRROR_RELEASE_IMAGE"
    echo "Mirror release image saved: ${TARGET_IMAGE}"

    # Copy local oc pull-secret with CI registry credentials to bastion
    oc registry login --to /tmp/ci-pull-secret.json
    # Merge CI credentials into the combined pull secret
    [[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
    set +x
    jq -s '.[0].auths * .[1].auths | {auths: .}' \
        /tmp/ci-pull-secret.json \
        /tmp/mirror-pull-secret.json > /tmp/combined-pull-secret.json
    if [[ "${WAS_TRACING}" == true ]]; then set -x; fi
    bastion_copy /tmp/combined-pull-secret.json /tmp/combined-pull-secret.json

    # Build the mirror command with sparse manifest filtering
    # --filter-by-os limits manifest-list entries to only the requested arches
    MIRROR_CMD="oc adm release mirror \
        -a /tmp/combined-pull-secret.json \
        --filter-by-os='${SPARSE_MANIFEST_ARCHES}' \
        --from='${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}' \
        --to='${TARGET_REPO}' \
        --to-release-image='${TARGET_IMAGE}' \
        --insecure=true \
        --print-mirror-instructions=idms"

    echo "Running sparse manifest mirror on bastion..."

    MAX_ATTEMPTS=3
    ATTEMPT=1
    SUCCESS=false
    while [ "${ATTEMPT}" -le "${MAX_ATTEMPTS}" ] && [ "${SUCCESS}" = false ]; do
        echo "Mirror attempt ${ATTEMPT}/${MAX_ATTEMPTS}"
        if ssh ${SSH_OPTS} root@"${BASTION_PUBLIC_IP}" "${MIRROR_CMD}" \
                > "${SHARED_DIR}/mirror_output.txt" 2>&1; then
            SUCCESS=true
            echo "Mirror succeeded on attempt ${ATTEMPT}"
        else
            echo "Mirror attempt ${ATTEMPT} failed. Retrying in 60s..."
            cat "${SHARED_DIR}/mirror_output.txt" || true
            sleep 60
        fi
        ATTEMPT=$(( ATTEMPT + 1 ))
    done

    if [ "${SUCCESS}" = false ]; then
        echo "[ERROR] Mirror failed after ${MAX_ATTEMPTS} attempts"
        cat "${SHARED_DIR}/mirror_output.txt" || true
        exit 1
    fi

    cat "${SHARED_DIR}/mirror_output.txt"
}

# ── 6. Apply the ImageDigestMirrorSet to the running cluster ──────────────────
# This ensures future image pulls (e.g. by workers added after install) use the
# local mirror instead of the public registry (OCPSTRAT-1808 sparse mirroring).
function apply_disconnected_mirror_config() {
    echo "=== Applying ImageDigestMirrorSet to running cluster (OCPSTRAT-1808) ==="

    IDMS_FILE="${SHARED_DIR}/idms-registry-mirror.yaml"
    if [ ! -s "${IDMS_FILE}" ]; then
        echo "[ERROR] IDMS file not found or empty at ${IDMS_FILE}. Cannot apply mirror config."
        return 1
    fi

    # Copy the IDMS manifest to the bastion where oc/kubeconfig are available
    # shellcheck disable=SC2086
    scp ${SSH_OPTS} "${IDMS_FILE}" root@"${BASTION_PUBLIC_IP}":/tmp/idms-registry-mirror.yaml

    # The local mirror registry serves plain HTTP.  CRI-O on every node will
    # reject pulls from it unless the cluster's image config lists the endpoint
    # in spec.registrySources.insecureRegistries.  Patch that before the IDMS
    # so both changes land in a single MCP roll-out cycle.
    echo "Patching image.config.openshift.io/cluster to allow insecure pulls from ${MIRROR_REGISTRY_HOST}"
    # shellcheck disable=SC2086
    ssh ${SSH_OPTS} root@"${BASTION_PUBLIC_IP}" \
        "oc patch image.config.openshift.io/cluster \
            --type=merge \
            -p '{\"spec\":{\"registrySources\":{\"insecureRegistries\":[\"${MIRROR_REGISTRY_HOST}\"]}}}' \
            --kubeconfig ~/.kube/config"

    echo "Applying ImageDigestMirrorSet to cluster"
    # shellcheck disable=SC2086
    ssh ${SSH_OPTS} root@"${BASTION_PUBLIC_IP}" \
        "oc apply -f /tmp/idms-registry-mirror.yaml --kubeconfig ~/.kube/config"

    echo "Waiting for MachineConfigPool to roll out the mirror configuration..."
    # shellcheck disable=SC2086
    if ! ssh ${SSH_OPTS} root@"${BASTION_PUBLIC_IP}" \
        "oc wait mcp master worker --for condition=Updated --timeout=20m --kubeconfig ~/.kube/config"; then
        echo "[ERROR] MachineConfigPool did not reach Updated condition within the timeout."
        echo "[ERROR] Mirror rollout failed — aborting to prevent e2e tests running against a broken mirror config."
        return 1
    fi

    echo "Mirror configuration applied successfully"
}

# ── 5. Parse mirror output → IDMS YAML for cluster install ────────────────────
function generate_idms() {
    echo "=== Generating IDMS (ImageDigestMirrorSet) from mirror output ==="

    MIRROR_OUTPUT="${SHARED_DIR}/mirror_output.txt"
    IDMS_FILE="${SHARED_DIR}/idms-registry-mirror.yaml"

    # Extract the IDMS block from mirror output
    # oc adm release mirror --print-mirror-instructions=idms outputs an IDMS manifest
    python3 - <<'PYEOF' "${MIRROR_OUTPUT}" "${IDMS_FILE}"
import sys, re

input_file = sys.argv[1]
output_file = sys.argv[2]

with open(input_file, 'r') as f:
    content = f.read()

# Find the IDMS block: starts with "---\napiVersion:" and ends before next "---" or EOF
pattern = r'(---\s*\napiVersion:\s*config\.openshift\.io/v1\s*\nkind:\s*ImageDigestMirrorSet.*?)(?=\n---|\Z)'
match = re.search(pattern, content, re.DOTALL)

if match:
    idms_block = match.group(1).strip()
    with open(output_file, 'w') as f:
        f.write(idms_block + '\n')
    print(f"IDMS written to {output_file}")
    print(idms_block)
else:
    # Fallback: write the entire mirror output section starting from "---"
    start = content.find('---\napiVersion: config.openshift.io')
    if start == -1:
        start = content.find('---\napiVersion: operator.openshift.io')
    if start != -1:
        with open(output_file, 'w') as f:
            f.write(content[start:])
        print(f"IDMS (fallback) written to {output_file}")
    else:
        print("[ERROR] Could not find IDMS block in mirror output. Cannot continue.")
        sys.exit(1)
PYEOF

    if [ -f "${IDMS_FILE}" ]; then
        echo "IDMS file content:"
        cat "${IDMS_FILE}"
    fi

    # Also write the install-config mirror patch for imageDigestSources
    # This is used in the tfvars to inform openshift-install about the mirror
    grep -A 9999 'imageDigestSources:' "${MIRROR_OUTPUT}" | \
        head -n -0 > "${SHARED_DIR}/install-config-mirror.yaml.patch" 2>/dev/null || true

    if [ -s "${SHARED_DIR}/install-config-mirror.yaml.patch" ]; then
        echo "install-config mirror patch:"
        cat "${SHARED_DIR}/install-config-mirror.yaml.patch"
    fi
}

# ── Main ───────────────────────────────────────────────────────────────────────

echo "Start sparse manifest mirror setup: $(date)"

if [ ! -f "${SHARED_DIR}/BASTION_PUBLIC_IP" ]; then
    echo "[ERROR] BASTION_PUBLIC_IP not found in SHARED_DIR. Was upi-install-powervs-cluster run first?"
    exit 1
fi

if [ ! -f "${IBMCLOUD_HOME}/ocp4-upi-powervs/data/id_rsa" ]; then
    echo "[ERROR] SSH key not found at ${IBMCLOUD_HOME}/ocp4-upi-powervs/data/id_rsa"
    echo "This step must run in the same pod sequence as upi-install-powervs-cluster"
    exit 1
fi

ensure_oc_on_bastion
setup_local_registry
prepare_pull_secret
mirror_release_image
generate_idms
if [ ! -s "${SHARED_DIR}/idms-registry-mirror.yaml" ]; then
    echo "[ERROR] idms-registry-mirror.yaml is missing or empty after generate_idms. Aborting."
    exit 1
fi
apply_disconnected_mirror_config

echo "Sparse manifest mirror setup complete: $(date)"
echo "Mirror registry : $(cat "${SHARED_DIR}/mirror_registry_url")"
echo "Mirrored image  : $(cat "${SHARED_DIR}/MIRROR_RELEASE_IMAGE")"
