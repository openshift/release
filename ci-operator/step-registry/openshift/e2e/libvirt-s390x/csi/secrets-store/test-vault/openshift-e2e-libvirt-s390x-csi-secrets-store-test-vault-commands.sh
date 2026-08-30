#!/bin/bash
# ==============================================================================
# Script to test the Secrets Store CSI Driver operator with HashiCorp Vault
# on OpenShift (s390x / IBM Z) in CI environment.
#
# Assumptions:
#   - setup-fbc-operator step has already been run successfully
#   - Vault credentials are mounted at /etc/hypershift-agent-ibmz-credentials
# ==============================================================================

set -euo pipefail

# Setup unprivileged tool installation path
export PATH="/tmp/bin:${PATH}"
mkdir -p /tmp/bin

# --- Configuration ---
VAULT_CREDS_DIR="/etc/hypershift-agent-ibmz-credentials"

# Vault license (just the license string, not a full YAML)
VAULT_LICENSE_STRING_FILE="${VAULT_CREDS_DIR}/vault-license"
VAULT_NAMESPACE="vault"

# Repo
REPO_URL="https://github.com/openshift/secrets-store-csi-driver"
REPO_DIR="/tmp/secrets-store-csi-driver"

# Image replacement — old image in test yamls → new s390x image
OLD_BUSYBOX_IMAGE="registry.k8s.io/e2e-test-images/busybox:1.29-4"
NEW_BUSYBOX_IMAGE="docker.io/s390x/busybox:latest"

# Test yaml files (relative to repo root) that need the busybox image replaced
BUSYBOX_YAML_FILES=(
    "test/bats/tests/vault/pod-vault-rotation.yaml"
    "test/bats/tests/vault/pod-vault-inline-volume-secretproviderclass.yaml"
    "test/bats/tests/vault/deployment-synck8s.yaml"
    "test/bats/tests/vault/deployment-two-synck8s.yaml"
    "test/bats/tests/vault/pod-vault-inline-volume-multiple-spc.yaml"
)

# vault.bats patch
BATS_FILE="test/bats/vault.bats"

# --- Helper ---
section() {
    echo
    echo "======================================================================"
    echo "  $*"
    echo "======================================================================"
}

# ==============================================================================
# STEP 0: Architecture check + dependency install
# ==============================================================================
check_arch_and_deps() {
    section "STEP 0: Architecture and Dependency Check"

    CLUSTER_ARCH=$(oc get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}' 2>/dev/null || echo "unknown")
    echo "Detected cluster architecture: ${CLUSTER_ARCH}"
    if [ "${CLUSTER_ARCH}" != "s390x" ]; then
        echo "ERROR: This script is intended for s390x (IBM Z) clusters."
        echo "       Detected cluster architecture: ${CLUSTER_ARCH}. Exiting."
        exit 1
    fi
    echo "Architecture check passed: s390x cluster confirmed."

    echo
    echo "Checking and installing required tools..."

    # Verify tools already present in cli image
    for tool in oc curl tar; do
        if ! command -v "${tool}" &>/dev/null; then
            echo "ERROR: Required tool '${tool}' not found in PATH."
            exit 1
        fi
        echo "  [OK] ${tool}"
    done

    # Install git if not present — try dnf 
    if ! command -v git &>/dev/null; then
        echo "git not found — attempting dnf install..."
        if dnf install -y git &>/dev/null 2>&1; then
            echo "  [OK] git $(git --version) (via dnf)"
        else
            echo "dnf unavailable or failed"
            exit 1
        fi
    else
        echo "  [OK] git $(git --version)"
    fi

    # Install jq to /tmp/bin if not present
    if ! command -v jq &>/dev/null; then
        echo "Installing jq (amd64 for build farm pod)..."
        JQ_VERSION="1.7.1"
        JQ_URL="https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/jq-linux-amd64"
        curl -fsSL "${JQ_URL}" -o /tmp/bin/jq || {
            echo "ERROR: Failed to download jq from ${JQ_URL}."
            exit 1
        }
        chmod +x /tmp/bin/jq
        echo "  [OK] jq $(jq --version)"
    else
        echo "  [OK] jq $(jq --version)"
    fi

    # Install bats to /tmp/bin if not present
    if ! command -v bats &>/dev/null; then
        echo "Installing bats (Bash Automated Testing System)..."
        BATS_VERSION="1.11.0"
        BATS_URL="https://github.com/bats-core/bats-core/archive/refs/tags/v${BATS_VERSION}.tar.gz"
        curl -fsSL "${BATS_URL}" -o /tmp/bats.tar.gz || {
            echo "ERROR: Failed to download bats from ${BATS_URL}."
            exit 1
        }
        tar -xzf /tmp/bats.tar.gz -C /tmp
        bash /tmp/bats-core-${BATS_VERSION}/install.sh /tmp/bin
        rm -rf /tmp/bats.tar.gz /tmp/bats-core-${BATS_VERSION}
        echo "  [OK] bats $(bats --version)"
    else
        echo "  [OK] bats $(bats --version)"
    fi

    # Install helm to /tmp/bin if not present
    if ! command -v helm &>/dev/null; then
        echo "Installing helm (amd64 for build farm pod)..."
        HELM_VERSION="4.2.4"
        HELM_URL="https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz"
        curl -fsSL "${HELM_URL}" -o /tmp/helm.tar.gz || {
            echo "ERROR: Failed to download helm from ${HELM_URL}."
            exit 1
        }
        tar -xzf /tmp/helm.tar.gz -C /tmp
        mv /tmp/linux-amd64/helm /tmp/bin/helm
        chmod +x /tmp/bin/helm
        rm -rf /tmp/helm.tar.gz /tmp/linux-amd64
        echo "  [OK] helm $(helm version --short)"
    else
        echo "  [OK] helm $(helm version --short)"
    fi

    echo
    echo "All dependency checks passed."
}

# ==============================================================================
# STEP 1: Validate required files exist
# ==============================================================================
validate_files() {
    section "STEP 1: Validating Required Files"

    local missing=0

    if [ ! -f "${VAULT_LICENSE_STRING_FILE}" ]; then
        echo "ERROR: Required file not found: ${VAULT_LICENSE_STRING_FILE}"
        missing=$(( missing + 1 ))
    else
        echo "  [OK] ${VAULT_LICENSE_STRING_FILE}"
        # Validate it's not empty
        if [ ! -s "${VAULT_LICENSE_STRING_FILE}" ]; then
            echo "ERROR: '${VAULT_LICENSE_STRING_FILE}' is empty."
            missing=$(( missing + 1 ))
        else
            echo "  [OK] vault-license file is not empty"
        fi
    fi

    if [ "${missing}" -gt 0 ]; then
        echo
        echo "ERROR: ${missing} required file(s) missing or invalid. Exiting."
        exit 1
    fi

    echo "All required files present and valid."
}

# ==============================================================================
# STEP 3: Clone the secrets-store-csi-driver repo
# ==============================================================================
clone_repo() {
    section "STEP 3: Cloning secrets-store-csi-driver Repository"

    if [ -d "${REPO_DIR}" ]; then
        echo "Repository already exists at '${REPO_DIR}'. Pulling latest changes..."
        git -C "${REPO_DIR}" pull --ff-only || {
            echo "WARNING: Could not fast-forward pull. Using existing checkout."
        }
    else
        echo "Cloning from ${REPO_URL}..."
        git clone "${REPO_URL}" "${REPO_DIR}"
        cd "${REPO_DIR}"
        echo "Checking out branch for release ${BRANCH}..."
        git checkout "release-${BRANCH}" || git checkout main
    fi

    echo "Repository ready at: ${REPO_DIR}"
}

# ==============================================================================
# STEP 4: Replace busybox image in test YAML files
# ==============================================================================
replace_busybox_images() {
    section "STEP 4: Replacing Busybox Image in Test YAML Files"

    echo "Replacing:"
    echo "  FROM: ${OLD_BUSYBOX_IMAGE}"
    echo "  TO  : ${NEW_BUSYBOX_IMAGE}"
    echo

    local replaced=0
    local not_found=0

    for rel_path in "${BUSYBOX_YAML_FILES[@]}"; do
        full_path="${REPO_DIR}/${rel_path}"

        if [ ! -f "${full_path}" ]; then
            echo "  [MISSING] ${rel_path}"
            not_found=$(( not_found + 1 ))
            continue
        fi

        if grep -qF "${OLD_BUSYBOX_IMAGE}" "${full_path}"; then
            sed -i "s|${OLD_BUSYBOX_IMAGE}|${NEW_BUSYBOX_IMAGE}|g" "${full_path}"
            echo "  [REPLACED] ${rel_path}"
            replaced=$(( replaced + 1 ))
        elif grep -qF "${NEW_BUSYBOX_IMAGE}" "${full_path}"; then
            echo "  [ALREADY SET] ${rel_path}"
            replaced=$(( replaced + 1 ))
        else
            echo "  [WARNING] '${OLD_BUSYBOX_IMAGE}' not found in ${rel_path}"
            not_found=$(( not_found + 1 ))
        fi
    done

    echo
    echo "Image replacement complete: ${replaced} file(s) updated, ${not_found} file(s) not matched."

    if [ "${not_found}" -gt 0 ]; then
        echo "WARNING: Some files were not patched. Continuing anyway."
    fi
}

# ==============================================================================
# STEP 5: Patch vault.bats — replace the helm install block
# ==============================================================================
patch_vault_bats() {
    section "STEP 5: Patching ${BATS_FILE}"

    BATS_FULL_PATH="${REPO_DIR}/${BATS_FILE}"

    if [ ! -f "${BATS_FULL_PATH}" ]; then
        echo "ERROR: ${BATS_FULL_PATH} not found."
        exit 1
    fi

    # Check if the patch has already been applied
    if grep -q "vault-enterprise" "${BATS_FULL_PATH}"; then
        echo "vault.bats already contains 'vault-enterprise' — patch already applied, skipping."
        return 0
    fi

    # Verify the old block exists
    if ! grep -q "helm install vault hashicorp/vault --namespace=vault" "${BATS_FULL_PATH}"; then
        echo "ERROR: Expected helm install block not found in ${BATS_FILE}."
        exit 1
    fi

    echo "Applying vault license apply line and helm install block replacement..."

    # Use Python for reliable multi-line replacement
    python3 - "${BATS_FULL_PATH}" "${VAULT_CREDS_DIR}" << 'PYEOF'
import sys, re

path = sys.argv[1]
creds_dir = sys.argv[2]
with open(path, 'r') as f:
    content = f.read()

# Patch 1: Insert vault-license secret creation before "# install the vault provider"
license_secret_creation = f'''  # Create vault-license secret from license string
  oc create namespace vault || true
  oc create secret generic vault-license \\
    --from-file=license={creds_dir}/vault-license \\
    -n vault --dry-run=client -o yaml | oc apply -f -
  
'''
vault_comment = '  # install the vault provider using the helm charts'

if 'vault-license' not in content or 'oc create secret' not in content:
    content = content.replace(
        vault_comment,
        license_secret_creation + vault_comment
    )

# Patch 2: Replace the old helm install block
old_helm_pattern = re.compile(
    r'  helm install vault hashicorp/vault --namespace=vault\s*\\\s*\n'
    r'(        --set [^\n]+\s*\\\s*\n)*'
    r'        --set "csi\.daemonSet\.providersDir=/var/run/secrets-store-csi-providers"',
    re.MULTILINE
)

new_helm_block = (
    '  helm install vault hashicorp/vault \\\n'
    '     --namespace vault \\\n'
    '     --create-namespace \\\n'
    '     --set server.dev.enabled=true \\\n'
    '     --set server.image.repository="docker.io/hashicorp/vault-enterprise" \\\n'
    '     --set server.image.tag="1.20.9-ent" \\\n'
    '     --set server.enterpriseLicense.secretName="vault-license" \\\n'
    '     --set server.logLevel=debug \\\n'
    '     --set server.serviceAccount.name="vault" \\\n'
    '     --set "injector.enabled=false" \\\n'
    '     --set global.openshift=true \\\n'
    '     --set csi.enabled=true \\\n'
    '     --set "csi.daemonSet.providersDir=/var/run/secrets-store-csi-providers" \\\n'
    '     --set csi.image.repository="registry.connect.redhat.com/hashicorp/vault-csi-provider" \\\n'
    '     --set csi.image.tag="1.7.1-ubi" \\\n'
    '     --set csi.agent.enabled=false'
)

new_content, n = old_helm_pattern.subn(new_helm_block, content)
if n == 0:
    print("ERROR: helm install pattern not matched.")
    sys.exit(1)

with open(path, 'w') as f:
    f.write(new_content)

print("vault.bats patched successfully.")
PYEOF

    echo "Patch complete."

    echo
    echo "Increasing all timeout values to 600s..."
    sed -i 's/--timeout=[0-9]\+[sm]/--timeout=600s/g' "${BATS_FULL_PATH}"
    echo "Timeout values updated."
}

# ==============================================================================
# Logging setup
# ==============================================================================
LOG_FILE="${ARTIFACT_DIR}/vault-test-$(date '+%Y%m%d-%H%M%S').log"
exec > >(tee -a "${LOG_FILE}") 2>&1

echo "Log file: ${LOG_FILE}"

# ==============================================================================
# collect_versions — record cluster + image versions
# ==============================================================================
collect_versions() {
    section "Version and Image Information"

    echo "--- Timestamp ---"
    date

    echo
    echo "--- OpenShift Cluster Version ---"
    oc get clusterversion version -o=jsonpath='{.status.desired.version}' 2>/dev/null || echo "(unavailable)"

    echo
    echo "--- Node Architecture ---"
    oc get nodes -o=jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.nodeInfo.architecture}{"\t"}{.status.nodeInfo.osImage}{"\n"}{end}' 2>/dev/null || echo "(unavailable)"

    echo
    echo "--- Secrets Store CSI Driver CSV ---"
    oc get csv -n openshift-cluster-csi-drivers --no-headers 2>/dev/null | grep secrets-store || echo "(no CSV found)"

    echo
    echo "--- Vault Helm Release ---"
    helm list -n "${VAULT_NAMESPACE}" 2>/dev/null || echo "(helm list failed)"

    echo
    echo "--- Vault Pod Images ---"
    oc get pods -n "${VAULT_NAMESPACE}" -o=jsonpath='{range .items[*]}{.metadata.name}{"\n"}{range .spec.containers[*]}  image: {.image}{"\n"}{end}{end}' 2>/dev/null || echo "(no vault pods)"

    echo
    echo "--- Busybox Image Used ---"
    echo "  ${NEW_BUSYBOX_IMAGE}"

    echo
    echo "--- Tool Versions ---"
    echo "  oc      : $(oc version --client 2>/dev/null | head -1)"
    echo "  helm    : $(helm version --short 2>/dev/null)"
    echo "  bats    : $(bats --version 2>/dev/null)"
}

# ==============================================================================
# collect_failure_logs — gather pod logs for diagnostics
# ==============================================================================
collect_failure_logs() {
    section "FAILURE DIAGNOSTICS — Collecting Pod Logs"

    echo "--- Timestamp of failure ---"
    date

    for ns in default "${VAULT_NAMESPACE}"; do
        echo
        echo "=== Namespace: ${ns} ==="

        echo
        echo "-- All pods --"
        oc get pods -n "${ns}" 2>/dev/null || echo "(could not list pods)"

        echo
        echo "-- Events (last 30) --"
        oc get events -n "${ns}" --sort-by='.lastTimestamp' 2>/dev/null | tail -30 || echo "(could not retrieve events)"

        PROBLEM_PODS=$(oc get pods -n "${ns}" --no-headers 2>/dev/null \
            | grep -vE '\s(Running|Completed)\s' \
            | awk '{print $1}' || true)

        if [ -n "${PROBLEM_PODS}" ]; then
            echo
            echo "-- Logs for non-Running/non-Completed pods --"
            for pod in ${PROBLEM_PODS}; do
                echo
                echo "  >>> Pod: ${pod} <<<"
                echo "  -- describe --"
                oc describe pod "${pod}" -n "${ns}" 2>/dev/null || true
                echo
                echo "  -- logs (all containers, last 100 lines) --"
                CONTAINERS=$(oc get pod "${pod}" -n "${ns}" \
                    -o=jsonpath='{range .spec.initContainers[*]}{.name}{"\n"}{end}{range .spec.containers[*]}{.name}{"\n"}{end}' \
                    2>/dev/null || true)
                for container in ${CONTAINERS}; do
                    echo "    [container: ${container}]"
                    oc logs "${pod}" -n "${ns}" -c "${container}" --tail=100 2>/dev/null || echo "    (logs unavailable)"
                done
            done
        else
            echo
            echo "  No problem pods found."
        fi
    done
}

# ==============================================================================
# cleanup_default_namespace — remove test resources
# ==============================================================================
cleanup_default_namespace() {
    section "Cleanup: Removing Test Resources from 'default' Namespace"

    echo "Deleting pods created by vault.bats..."

    for resource in pods deployments secretproviderclasses; do
        echo
        echo "-- ${resource} --"
        ITEMS=$(oc get "${resource}" -n default --no-headers 2>/dev/null \
            | grep -iE 'vault|secrets-store|busybox|synck8s|rotation|inline' \
            | awk '{print $1}' || true)
        if [ -n "${ITEMS}" ]; then
            for item in ${ITEMS}; do
                echo "  Deleting ${resource}/${item}..."
                oc delete "${resource}" "${item}" -n default --ignore-not-found 2>/dev/null || true
            done
        else
            echo "  Nothing to clean up."
        fi
    done

    echo
    echo "Cleanup complete."
}

# ==============================================================================
# on_exit — trap handler
# ==============================================================================
BATS_EXIT_CODE=0

on_exit() {
    local exit_code=$?

    [ "${BATS_EXIT_CODE}" -ne 0 ] && exit_code="${BATS_EXIT_CODE}"

    echo
    echo "======================================================================"
    if [ "${exit_code}" -eq 0 ]; then
        echo "  EXIT: SUCCESS"
    else
        echo "  EXIT: FAILURE (exit code: ${exit_code})"
    fi
    echo "======================================================================"

    if [ "${exit_code}" -eq 0 ]; then
        cleanup_default_namespace
        section "All Tests Passed"
        echo "Log file: ${LOG_FILE}"
    else
        collect_failure_logs
        section "Tests FAILED — Resources left for investigation"
        echo "Full log: ${LOG_FILE}"
    fi
}

trap on_exit EXIT

# ==============================================================================
# STEP 6: Run vault.bats tests
# ==============================================================================
run_bats_tests() {
    section "STEP 6: Running vault.bats Tests"

    local bats_full="${REPO_DIR}/${BATS_FILE}"

    if [ ! -f "${bats_full}" ]; then
        echo "ERROR: ${bats_full} not found."
        exit 1
    fi

    echo "Switching to 'default' namespace..."
    oc project default

    echo "Working directory: ${REPO_DIR}"
    echo "Running: bats --trace --verbose-run --show-output-of-passing-tests ${BATS_FILE}"
    echo

    cd "${REPO_DIR}"

    set +e
    bats --trace --verbose-run --show-output-of-passing-tests ${BATS_FILE}
    BATS_EXIT_CODE=$?
    set -e

    if [ "${BATS_EXIT_CODE}" -eq 0 ]; then
        echo
        echo "All vault.bats tests passed."
    else
        echo
        echo "ERROR: vault.bats exited with code ${BATS_EXIT_CODE}"
    fi

    cd -
}

# ==============================================================================
# Main
# ==============================================================================
collect_versions
check_arch_and_deps
validate_files
clone_repo
replace_busybox_images
patch_vault_bats
run_bats_tests

exit "${BATS_EXIT_CODE}"
