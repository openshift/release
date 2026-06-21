#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ cluster-tool boot ************"
echo "CLUSTER_TOOL_COMMIT: ${CLUSTER_TOOL_COMMIT}"
echo "CLUSTER_TOOL_FLAVOR_IMAGE: ${CLUSTER_TOOL_FLAVOR_IMAGE}"
echo "E2E_NAMESPACE: ${E2E_NAMESPACE}"
echo "E2E_KUSTOMIZE_OVERLAY: ${E2E_KUSTOMIZE_OVERLAY}"
echo "E2E_VM_TEMPLATE: ${E2E_VM_TEMPLATE}"
echo "OSAC_INSTALLER_IMAGE: ${OSAC_INSTALLER_IMAGE}"
echo "CLUSTER_TOOL_FLAVOR_NAME: ${CLUSTER_TOOL_FLAVOR_NAME}"
echo "COMPONENT_IMAGE: ${COMPONENT_IMAGE:-<none>}"
echo "COMPONENT_IMAGE_NAME: ${COMPONENT_IMAGE_NAME:-<none>}"
echo "E2E_CLUSTER_TEMPLATE: ${E2E_CLUSTER_TEMPLATE:-<none>}"
echo "-------------------------------------------"

# === Create ssh_config from ofcir-acquire output ===
IP=$(cat "${SHARED_DIR}/server-ip")
PORT=22
if [[ -f "${SHARED_DIR}/server-sshport" ]]; then
    PORT=$(<"${SHARED_DIR}/server-sshport")
fi

cat > "${SHARED_DIR}/ssh_config" <<SSHEOF
Host ci_machine
    HostName ${IP}
    User root
    Port ${PORT}
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    ServerAliveInterval 90
    LogLevel ERROR
    IdentityFile ${CLUSTER_PROFILE_DIR}/packet-ssh-key
SSHEOF

echo "SSH config created for ${IP}:${PORT}"

# === Wait for SSH ===
echo "Waiting for SSH to be ready..."
for i in $(seq 30); do
    ssh -F "${SHARED_DIR}/ssh_config" ci_machine hostname 2>/dev/null && break
    echo "  attempt ${i}/30 - retrying in 10s..."
    sleep 10
done
ssh -F "${SHARED_DIR}/ssh_config" ci_machine hostname 2>/dev/null || {
    echo "ERROR: SSH to ${IP}:${PORT} never became available after 30 attempts"
    exit 1
}

# === Build merged pull-secret with CI registry credentials ===
# The old workflow gets CI registry auth via dev-scripts setup; cluster-tool
# skips that. Download oc and use oc registry login (the standard CI pattern).
echo "Building pull secret..."
echo "  Cluster profile registries: $(jq -r '.auths | keys | join(", ")' ${CLUSTER_PROFILE_DIR}/pull-secret 2>/dev/null || echo 'PARSE ERROR')"

echo "  Downloading oc client..."
curl -fsSL https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz \
    | tar xzf - -C /tmp oc
echo "  Getting CI registry credentials via oc registry login..."
KUBECONFIG="" /tmp/oc registry login --to=/tmp/ci-pull-creds.json
echo "  CI registry creds: $(jq -r '.auths | keys | join(", ")' /tmp/ci-pull-creds.json 2>/dev/null || echo 'PARSE ERROR')"

jq -s 'reduce .[] as $x ({}; . * $x)' \
    "${CLUSTER_PROFILE_DIR}/pull-secret" \
    /tmp/ci-pull-creds.json \
    > /tmp/merged-pull-secret.json
echo "  Merged registries: $(jq -r '.auths | keys | join(", ")' /tmp/merged-pull-secret.json 2>/dev/null || echo 'PARSE ERROR')"

echo "Copying pull secret to machine..."
timeout -s 9 2m scp -F "${SHARED_DIR}/ssh_config" \
    /tmp/merged-pull-secret.json \
    ci_machine:/root/pull-secret

echo "Copying AAP license to machine..."
base64 -d /var/run/osac-installer-aap/license > /tmp/license.zip
timeout -s 9 2m scp -F "${SHARED_DIR}/ssh_config" \
    /tmp/license.zip \
    ci_machine:/tmp/license.zip

# === Determine fork repo URL for AAP project sync ===
AAP_SOURCE_REPO_URL=""
if [[ -n "${PULL_NUMBER:-}" ]] && [[ "${REPO_NAME:-}" == "osac-aap" ]]; then
    PR_AUTHOR=$(echo "${JOB_SPEC}" | jq -r '.refs.pulls[0].author // empty' 2>/dev/null || true)
    if [[ -n "${PR_AUTHOR}" ]] && [[ "${PR_AUTHOR}" != "${REPO_OWNER:-}" ]]; then
        CANDIDATE_URL="https://github.com/${PR_AUTHOR}/${REPO_NAME}"
        if curl -sfI "${CANDIDATE_URL}" &>/dev/null; then
            AAP_SOURCE_REPO_URL="${CANDIDATE_URL}.git"
            echo "Fork PR detected, AAP source repo: ${AAP_SOURCE_REPO_URL}"
        fi
    fi
fi

# === Write boot script to machine and execute ===
echo "Creating boot script on machine..."
timeout -s 9 1m ssh -F "${SHARED_DIR}/ssh_config" ci_machine bash -c 'cat > /root/boot.sh' <<'REMOTE_SCRIPT'
set -euo pipefail

COMMIT="$1"
FLAVOR_IMAGE="$2"
CLONE="$3"
INSTALLER_IMAGE="$4"
KUSTOMIZE_OVERLAY="$5"
VM_TEMPLATE="$6"
COMPONENT_IMAGE="${7:-}"
COMPONENT_IMAGE_NAME="${8:-}"
NAMESPACE="${9:-osac-e2e-ci}"
AAP_SOURCE_REPO_URL="${10:-}"
CLUSTER_TEMPLATE="${11:-}"

_timer() {
    local elapsed=$(( $(date +%s) - $1 ))
    printf "[TIMING] %s: %dm %ds\n" "$2" $((elapsed/60)) $((elapsed%60))
}

BOOT_TOTAL_START=$(date +%s)

# --- Phase 1: cluster-tool setup ---
SETUP_START=$(date +%s)
echo "=== Downloading cluster-tool ==="
curl -fsSL "https://raw.githubusercontent.com/omer-vishlitzky/cluster-tool/${COMMIT}/cluster-tool" \
    -o /usr/local/bin/cluster-tool
chmod +x /usr/local/bin/cluster-tool

echo "=== Setting up DNS (standalone dnsmasq) ==="
ORIG_DNS=$(grep nameserver /etc/resolv.conf 2>/dev/null | awk '{print $2}' | head -1)
ORIG_DNS=${ORIG_DNS:-8.8.8.8}

dnf install -y dnsmasq jq
mkdir -p /etc/NetworkManager/dnsmasq.d /etc/dnsmasq.d /etc/NetworkManager/conf.d

systemctl stop systemd-resolved 2>/dev/null || true
systemctl disable systemd-resolved 2>/dev/null || true

echo -e '[main]\ndns=none' > /etc/NetworkManager/conf.d/cluster-tool-dns.conf
systemctl restart NetworkManager

cat > /etc/dnsmasq.d/cluster-tool.conf <<DNSEOF
listen-address=127.0.0.1
bind-interfaces
server=${ORIG_DNS}
conf-dir=/etc/NetworkManager/dnsmasq.d
DNSEOF

systemctl enable --now dnsmasq
echo "nameserver 127.0.0.1" > /etc/resolv.conf
echo "DNS ready (standalone dnsmasq, upstream=${ORIG_DNS})"

echo "=== Setting up server ==="
python3 /usr/local/bin/cluster-tool connect ci --host local --data-path /home/cluster-tool
_timer $SETUP_START "Setup (cluster-tool + DNS + server)"

# --- Phase 2: pull + boot ---
echo "=== Setting up container auth ==="
mkdir -p /root/.config/containers
cp /root/pull-secret /root/.config/containers/auth.json

PULL_START=$(date +%s)
echo "=== Pulling OSAC vmaas flavor ==="
python3 /usr/local/bin/cluster-tool pull "${FLAVOR_IMAGE}"
_timer $PULL_START "Pull flavor"

CLUSTER_BOOT_START=$(date +%s)
echo "=== Booting cluster ==="
python3 /usr/local/bin/cluster-tool boot --flavor "${CLONE}" --name "${CLONE}"
_timer $CLUSTER_BOOT_START "Boot cluster"

systemctl restart dnsmasq

# --- Phase 3: configure access ---
KUBECONFIG_PATH="/root/.kube/${CLONE}.kubeconfig"
echo "export KUBECONFIG=${KUBECONFIG_PATH}" >> /root/.bashrc
export KUBECONFIG="${KUBECONFIG_PATH}"

echo "=== Installing oc ==="
curl -fsSL https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz \
    | tar xzf - -C /usr/local/bin oc kubectl

echo "=== Installing osac from installer image ==="
podman run --authfile /root/pull-secret --rm \
    -v /usr/local/bin:/target:z \
    "${INSTALLER_IMAGE}" \
    cp /usr/local/bin/osac /target/osac

echo "=== Updating cluster pull secret ==="
oc set data secret/pull-secret -n openshift-config \
    --from-file=.dockerconfigjson=/root/pull-secret

# --- Phase 4: component override (conditional) ---
COMPONENT_OVERRIDE_CMD=""
if [[ -n "${COMPONENT_IMAGE}" ]] && [[ -n "${COMPONENT_IMAGE_NAME}" ]]; then
    echo "=== Component override: ${COMPONENT_IMAGE_NAME} ==="
    COMPONENT_OVERRIDE_CMD="curl -fsSL https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv5.6.0/kustomize_v5.6.0_linux_amd64.tar.gz | tar xzf - -C /usr/local/bin && cd /installer/base && kustomize edit set image ${COMPONENT_IMAGE_NAME}=${COMPONENT_IMAGE} && cd /installer && "
fi

# When testing an osac-aap PR, the installer-with-pr image contains
# .aap-source-sha with the PR's head commit SHA. Override both
# AAP_PROJECT_GIT_BRANCH (playbook sync) and AAP_EE_IMAGE (execution
# environment) so AAP uses the PR's code instead of the pinned versions.
AAP_OVERRIDE_CMD=""
AAP_SOURCE_SHA=$(podman run --authfile /root/pull-secret --rm "${INSTALLER_IMAGE}" cat /installer/.aap-source-sha 2>/dev/null || true)
if [[ -n "${AAP_SOURCE_SHA}" ]]; then
    echo "=== AAP project git ref override: ${AAP_SOURCE_SHA} ==="
    AAP_OVERRIDE_CMD="sed -i 's|AAP_PROJECT_GIT_BRANCH=.*|AAP_PROJECT_GIT_BRANCH=${AAP_SOURCE_SHA}|' /installer/overlays/${KUSTOMIZE_OVERLAY}/kustomization.yaml && grep -q 'AAP_PROJECT_GIT_BRANCH=${AAP_SOURCE_SHA}' /installer/overlays/${KUSTOMIZE_OVERLAY}/kustomization.yaml || { echo 'ERROR: AAP_PROJECT_GIT_BRANCH override failed'; exit 1; } && "
    if [[ -n "${AAP_SOURCE_REPO_URL}" ]]; then
        echo "=== AAP project git URI override: ${AAP_SOURCE_REPO_URL} ==="
        AAP_OVERRIDE_CMD="${AAP_OVERRIDE_CMD}sed -i 's|AAP_PROJECT_GIT_URI=.*|AAP_PROJECT_GIT_URI=${AAP_SOURCE_REPO_URL}|' /installer/overlays/${KUSTOMIZE_OVERLAY}/kustomization.yaml && grep -q 'AAP_PROJECT_GIT_URI=${AAP_SOURCE_REPO_URL}' /installer/overlays/${KUSTOMIZE_OVERLAY}/kustomization.yaml || { echo 'ERROR: AAP_PROJECT_GIT_URI override failed'; exit 1; } && "
    fi
    if [[ -n "${COMPONENT_IMAGE}" ]]; then
        echo "=== AAP EE image override: ${COMPONENT_IMAGE} ==="
        AAP_OVERRIDE_CMD="${AAP_OVERRIDE_CMD}sed -i 's|AAP_EE_IMAGE=.*|AAP_EE_IMAGE=${COMPONENT_IMAGE}|' /installer/overlays/${KUSTOMIZE_OVERLAY}/kustomization.yaml && grep -q 'AAP_EE_IMAGE=${COMPONENT_IMAGE}' /installer/overlays/${KUSTOMIZE_OVERLAY}/kustomization.yaml || { echo 'ERROR: AAP_EE_IMAGE override failed'; exit 1; } && "
    fi
fi

# --- Phase 5: refresh ---
REFRESH_START=$(date +%s)
echo "=== Running refresh ==="
podman run --authfile /root/pull-secret --rm --network=host \
    -v "${KUBECONFIG_PATH}":/root/.kube/config:z \
    -v /root/pull-secret:/installer/overlays/${KUSTOMIZE_OVERLAY}/files/quay-pull-secret.json:z \
    -v /tmp/license.zip:/installer/overlays/${KUSTOMIZE_OVERLAY}/files/license.zip:z \
    -e KUBECONFIG=/root/.kube/config \
    -e INSTALLER_KUSTOMIZE_OVERLAY="${KUSTOMIZE_OVERLAY}" \
    -e INSTALLER_VM_TEMPLATE="${VM_TEMPLATE}" \
    -e INSTALLER_CLUSTER_TEMPLATE="${CLUSTER_TEMPLATE}" \
    -e INSTALLER_NAMESPACE="${NAMESPACE}" \
    "${INSTALLER_IMAGE}" \
    bash -c "${COMPONENT_OVERRIDE_CMD}${AAP_OVERRIDE_CMD}cd /installer && sh scripts/refresh-after-snapshot.sh"
_timer $REFRESH_START "Refresh"

echo ""
echo "=== Boot + refresh complete ==="
_timer $BOOT_TOTAL_START "Total (setup + pull + boot + refresh)"
REMOTE_SCRIPT

echo "Executing boot script on machine..."
timeout -s 9 "${BOOT_TIMEOUT}" ssh -F "${SHARED_DIR}/ssh_config" ci_machine \
    "bash /root/boot.sh \
    '${CLUSTER_TOOL_COMMIT}' \
    '${CLUSTER_TOOL_FLAVOR_IMAGE}' \
    '${CLUSTER_TOOL_FLAVOR_NAME}' \
    '${OSAC_INSTALLER_IMAGE}' \
    '${E2E_KUSTOMIZE_OVERLAY}' \
    '${E2E_VM_TEMPLATE}' \
    '${COMPONENT_IMAGE:-}' \
    '${COMPONENT_IMAGE_NAME:-}' \
    '${E2E_NAMESPACE}' \
    '${AAP_SOURCE_REPO_URL:-}' \
    '${E2E_CLUSTER_TEMPLATE:-}'"

echo "Boot step finished successfully."
