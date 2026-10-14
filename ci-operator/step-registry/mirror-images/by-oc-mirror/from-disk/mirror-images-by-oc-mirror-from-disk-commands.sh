#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
EXIT_CODE=100
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"' EXIT TERM

if [[ "${MIRROR_BIN}" != "oc-mirror" ]]; then
  echo "MIRROR_BIN is '${MIRROR_BIN}', not 'oc-mirror' — skipping disk-to-mirror step."
  exit 0
fi

export HOME="${HOME:-/tmp/home}"
export XDG_RUNTIME_DIR="${HOME}/run"
mkdir -p "${XDG_RUNTIME_DIR}"

function run_command() {
    local CMD="$1"
    echo "Running command: ${CMD}"
    eval "${CMD}"
}

# Ensure our UID is in /etc/passwd — required to SSH from this container
if ! whoami &> /dev/null; then
    if [[ -w /etc/passwd ]]; then
        echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
    else
        echo "/etc/passwd is not writeable, and user matching this uid is not found."
        exit 1
    fi
fi

SSH_KEY="${CLUSTER_PROFILE_DIR}/ssh-privatekey"
BASTION_IP=$(head -n 1 "${SHARED_DIR}/bastion_public_address")
BASTION_SSH_USER=$(head -n 1 "${SHARED_DIR}/bastion_ssh_user")
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ${SSH_KEY}"

echo "Bastion: ${BASTION_SSH_USER}@${BASTION_IP}"

# private mirror registry host: <public_dns>:<port>
# The TLS cert on the bastion registry is issued for this hostname, so the
# push destination must use it — not 'localhost:5000'.
MIRROR_REGISTRY_HOST=$(head -n 1 "${SHARED_DIR}/mirror_registry_url")
echo "MIRROR_REGISTRY_HOST: ${MIRROR_REGISTRY_HOST}"

echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE: ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
if [[ -z "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" ]]; then
  echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE is empty, exiting"
  exit 1
fi

# Verify the workspace was staged by the to-disk step
BASTION_WORKSPACE_PATH="/tmp/oc-mirror-workspace"
if [[ -f "${SHARED_DIR}/oc-mirror-workspace-path" ]]; then
    BASTION_WORKSPACE_PATH=$(cat "${SHARED_DIR}/oc-mirror-workspace-path")
fi
echo "Bastion workspace path: ${BASTION_WORKSPACE_PATH}"

# Verify the oc-mirror binary and workspace exist on the bastion before proceeding
ssh ${SSH_OPTS} "${BASTION_SSH_USER}@${BASTION_IP}" \
    "test -x /tmp/oc-mirror || { echo 'ERROR: /tmp/oc-mirror not found on bastion'; exit 1; }; \
     test -d '${BASTION_WORKSPACE_PATH}/working-dir' || { echo 'ERROR: workspace not found on bastion at ${BASTION_WORKSPACE_PATH}'; exit 1; }; \
     echo 'oc-mirror binary and workspace verified on bastion.'; \
     /tmp/oc-mirror version --output=yaml"

# Build pull secret with registry credentials (Option B: this step independently
# manages its own credentials from the openshift-qe/mirror-registry vault mount).
# Disable tracing for this block — registry_creds is sensitive.
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
registry_cred=$(head -n 1 "/var/run/vault/mirror-registry/registry_creds" | tr -d '\n' | base64 -w 0)
pull_secret_local=$(mktemp)
cat "${CLUSTER_PROFILE_DIR}/pull-secret" | python3 -c \
    'import json,sys;j=json.load(sys.stdin);a=j["auths"];a["'${MIRROR_REGISTRY_HOST}'"]={"auth":"'${registry_cred}'"};j["auths"]=a;print(json.dumps(j))' \
    > "${pull_secret_local}"
# Transfer pull secret to bastion
scp ${SSH_OPTS} "${pull_secret_local}" "${BASTION_SSH_USER}@${BASTION_IP}:/tmp/oc-mirror-pull-secret.json"
rm -f "${pull_secret_local}"
$WAS_TRACING && set -x
echo "Pull secret transferred to bastion."

# Write the ImageSetConfiguration on the bastion
# (same ISC as to-disk; oc-mirror needs it in disk-to-mirror mode to generate
# the correct IDMS/ITMS cluster-resources)
ISC_PATH="${BASTION_WORKSPACE_PATH}/image-set-config.yaml"
# shellcheck disable=SC2087  # Intentionally unquoted: ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE} must expand client-side
ssh ${SSH_OPTS} "${BASTION_SSH_USER}@${BASTION_IP}" "cat > '${ISC_PATH}'" <<EOF
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  platform:
    release: ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}
EOF
echo "ImageSetConfiguration written on bastion at ${ISC_PATH}"

# ---------------------------------------------------------------------------
# Isolation enforcement
# Block all outbound internet traffic on the bastion before running disk-to-mirror.
# This enforces the no-public-internet boundary: oc-mirror must be able to push
# from the local archive to the local registry without any external network access.
#
# Exemptions:
#   - lo (loopback)
#   - ESTABLISHED/RELATED (responses to already-open connections, e.g. our SSH session)
#   - 10.0.0.0/8 (VPC-internal: covers AWS private endpoints for EC2/ELB/STS/S3)
#   - 169.254.169.254/32 (AWS instance metadata)
#
# The iptables rules are restored after the import so subsequent post-steps
# (deprovision, artifact gathering) are not affected.
# ---------------------------------------------------------------------------
echo "=== Enforcing network isolation on bastion ==="
ssh ${SSH_OPTS} "${BASTION_SSH_USER}@${BASTION_IP}" bash <<'ENDSSH'
set -euo pipefail
echo "Saving current iptables rules..."
sudo iptables-save > /tmp/iptables-before-import.rules
echo "Current OUTPUT chain:"
sudo iptables -L OUTPUT -n -v

echo "Inserting isolation rules..."
# Permit loopback
sudo iptables -I OUTPUT 1 -o lo -j ACCEPT
# Permit established/related (keeps our SSH session alive)
sudo iptables -I OUTPUT 2 -m state --state ESTABLISHED,RELATED -j ACCEPT
# Permit VPC-internal (AWS private endpoints: ec2, elb, sts, s3)
sudo iptables -I OUTPUT 3 -d 10.0.0.0/8 -j ACCEPT
# Permit instance metadata
sudo iptables -I OUTPUT 4 -d 169.254.169.254/32 -j ACCEPT
# Drop all other outbound
sudo iptables -A OUTPUT -j DROP

echo "Isolation rules applied. OUTPUT chain:"
sudo iptables -L OUTPUT -n -v
ENDSSH
echo "Network isolation enforced on bastion."

# ---------------------------------------------------------------------------
# Isolation acceptance test
# Verify that public internet is unreachable and the local registry is reachable
# before proceeding with disk-to-mirror. Fail fast if either check is wrong.
# ---------------------------------------------------------------------------
echo "=== Isolation acceptance test ==="
ssh ${SSH_OPTS} "${BASTION_SSH_USER}@${BASTION_IP}" bash <<'ENDSSH'
set -euo pipefail
echo "--- Test 1: public internet must be blocked ---"
if curl -m 10 --silent --output /dev/null https://quay.io; then
    echo "FAIL: quay.io is reachable — isolation is broken"
    exit 1
else
    echo "PASS: quay.io is not reachable (internet blocked as expected)"
fi

echo "--- Test 2: local mirror registry must be reachable ---"
if curl -m 10 --silent --output /dev/null --insecure https://localhost:5000; then
    echo "PASS: local registry at localhost:5000 is reachable"
else
    echo "FAIL: local registry at localhost:5000 is not reachable"
    exit 1
fi
ENDSSH
echo "Isolation acceptance test passed."

# Save the iptables state during isolation to ARTIFACT_DIR for audit/debugging
ssh ${SSH_OPTS} "${BASTION_SSH_USER}@${BASTION_IP}" \
    "sudo iptables -L -n -v" > "${ARTIFACT_DIR}/bastion-iptables-during-import.txt" 2>&1 || true

# ---------------------------------------------------------------------------
# Disk-to-mirror (Phase 2)
# Run oc-mirror on the bastion in disk-to-mirror mode.
# The destination is docker://<mirror-registry-host> with no repo suffix —
# oc-mirror reconstructs per-image paths from the archive metadata.
# ---------------------------------------------------------------------------
echo "=== Running disk-to-mirror (Phase 2) on bastion ==="
ssh ${SSH_OPTS} "${BASTION_SSH_USER}@${BASTION_IP}" \
    "/tmp/oc-mirror -c '${ISC_PATH}' \
        --from file://${BASTION_WORKSPACE_PATH} \
        docker://${MIRROR_REGISTRY_HOST} \
        --dest-tls-verify=false --v2"
echo "Disk-to-mirror complete."

# ---------------------------------------------------------------------------
# Restore iptables rules
# Restore before copying artifacts so that if scp/ssh fails we still restore.
# ---------------------------------------------------------------------------
echo "=== Restoring iptables rules on bastion ==="
ssh ${SSH_OPTS} "${BASTION_SSH_USER}@${BASTION_IP}" \
    "sudo iptables-restore < /tmp/iptables-before-import.rules"
echo "iptables rules restored."

# Save the restored iptables state for comparison
ssh ${SSH_OPTS} "${BASTION_SSH_USER}@${BASTION_IP}" \
    "sudo iptables -L -n -v" > "${ARTIFACT_DIR}/bastion-iptables-post-restore.txt" 2>&1 || true

# ---------------------------------------------------------------------------
# Copy IDMS/ITMS from bastion to SHARED_DIR
# disk-to-mirror produces cluster-resources under the workspace's working-dir.
# The subsequent mirror-images-by-oc-mirror-conf-mirror step reads these files.
# ---------------------------------------------------------------------------
echo "=== Copying IDMS/ITMS from bastion to SHARED_DIR ==="
BASTION_CLUSTER_RESOURCES="${BASTION_WORKSPACE_PATH}/working-dir/cluster-resources"

idms_remote="${BASTION_CLUSTER_RESOURCES}/idms-oc-mirror.yaml"
idms_local="/tmp/idms-oc-mirror.yaml"

# Verify idms was produced (fail clearly if disk-to-mirror did not generate it)
ssh ${SSH_OPTS} "${BASTION_SSH_USER}@${BASTION_IP}" \
    "test -s '${idms_remote}' || { echo 'ERROR: idms-oc-mirror.yaml not found at ${idms_remote} after disk-to-mirror'; ls -la '${BASTION_CLUSTER_RESOURCES}/' 2>/dev/null || true; exit 1; }"

scp ${SSH_OPTS} "${BASTION_SSH_USER}@${BASTION_IP}:${idms_remote}" "${idms_local}"
cp "${idms_local}" "${SHARED_DIR}/idms-oc-mirror.yaml"
echo "IDMS saved to SHARED_DIR/idms-oc-mirror.yaml:"
cat "${SHARED_DIR}/idms-oc-mirror.yaml"

# ITMS is optional (only present when tag mirrors are needed)
itms_remote="${BASTION_CLUSTER_RESOURCES}/itms-oc-mirror.yaml"
itms_local="/tmp/itms-oc-mirror.yaml"
if ssh ${SSH_OPTS} "${BASTION_SSH_USER}@${BASTION_IP}" "test -s '${itms_remote}'"; then
    scp ${SSH_OPTS} "${BASTION_SSH_USER}@${BASTION_IP}:${itms_remote}" "${itms_local}"
    cp "${itms_local}" "${SHARED_DIR}/itms-oc-mirror.yaml"
    echo "ITMS saved to SHARED_DIR/itms-oc-mirror.yaml:"
    cat "${SHARED_DIR}/itms-oc-mirror.yaml"
else
    echo "itms-oc-mirror.yaml not found on bastion — skipping (not required)."
fi

echo "=== disk-to-mirror (Phase 2) complete ==="
echo "IDMS/ITMS are now in SHARED_DIR, ready for mirror-images-by-oc-mirror-conf-mirror."
