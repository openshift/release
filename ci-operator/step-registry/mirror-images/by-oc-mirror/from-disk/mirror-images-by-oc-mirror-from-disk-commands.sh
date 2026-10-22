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
BASTION_PRIVATE_IP=$(head -n 1 "${SHARED_DIR}/bastion_private_address")
BASTION_SSH_USER=$(head -n 1 "${SHARED_DIR}/bastion_ssh_user")
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ${SSH_KEY}"

echo "Bastion public:  ${BASTION_SSH_USER}@${BASTION_IP}"
echo "Bastion private: ${BASTION_PRIVATE_IP}"

# private mirror registry host: <public_dns>:<port>
# The TLS cert on the bastion registry is issued for this hostname.
MIRROR_REGISTRY_HOST=$(head -n 1 "${SHARED_DIR}/mirror_registry_url")
echo "MIRROR_REGISTRY_HOST: ${MIRROR_REGISTRY_HOST}"
MIRROR_REGISTRY_HOSTNAME="${MIRROR_REGISTRY_HOST%%:*}"   # strip :port
MIRROR_REGISTRY_PORT="${MIRROR_REGISTRY_HOST##*:}"       # just the port number

echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE: ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
if [[ -z "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" ]]; then
  echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE is empty, exiting"
  exit 1
fi

# Verify the workspace was staged by the to-disk step
BASTION_WORKSPACE_PATH="/var/tmp/oc-mirror-workspace"
if [[ -f "${SHARED_DIR}/oc-mirror-workspace-path" ]]; then
    BASTION_WORKSPACE_PATH=$(cat "${SHARED_DIR}/oc-mirror-workspace-path")
fi
echo "Bastion workspace path: ${BASTION_WORKSPACE_PATH}"

# Read the binary path written by the to-disk step; fall back to the
# /var/tmp location so this step works even if re-run independently.
BASTION_BIN_PATH="/var/tmp/oc-mirror/oc-mirror"
if [[ -f "${SHARED_DIR}/oc-mirror-bin-path" ]]; then
    BASTION_BIN_PATH=$(cat "${SHARED_DIR}/oc-mirror-bin-path")
fi
echo "Bastion oc-mirror binary path: ${BASTION_BIN_PATH}"

# Verify the oc-mirror binary and workspace exist on the bastion
ssh ${SSH_OPTS} "${BASTION_SSH_USER}@${BASTION_IP}" \
    "test -x '${BASTION_BIN_PATH}' || { echo 'ERROR: ${BASTION_BIN_PATH} not found on bastion'; exit 1; }; \
     test -d '${BASTION_WORKSPACE_PATH}/working-dir' || { echo 'ERROR: workspace missing at ${BASTION_WORKSPACE_PATH}'; exit 1; }; \
     echo 'oc-mirror binary and workspace verified.'; \
     '${BASTION_BIN_PATH}' version --output=yaml"

# ---------------------------------------------------------------------------
# Registry credentials
# Disable tracing — registry_creds is sensitive.
# ---------------------------------------------------------------------------
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
registry_cred=$(head -n 1 "/var/run/vault/mirror-registry/registry_creds" | tr -d '\n' | base64 -w 0)
pull_secret_local=$(mktemp)
cat "${CLUSTER_PROFILE_DIR}/pull-secret" | python3 -c \
    'import json,sys;j=json.load(sys.stdin);a=j["auths"];a["'${MIRROR_REGISTRY_HOST}'"]={"auth":"'${registry_cred}'"};j["auths"]=a;print(json.dumps(j))' \
    > "${pull_secret_local}"
# Transfer pull secret to bastion; install into oc-mirror's expected auth location.
# oc-mirror (v2) reads credentials from $XDG_RUNTIME_DIR/containers/auth.json.
scp ${SSH_OPTS} "${pull_secret_local}" "${BASTION_SSH_USER}@${BASTION_IP}:/tmp/oc-mirror-pull-secret.json"
rm -f "${pull_secret_local}"
$WAS_TRACING && set -x
ssh ${SSH_OPTS} "${BASTION_SSH_USER}@${BASTION_IP}" \
    'xdg="${XDG_RUNTIME_DIR:-${HOME}/run}"; mkdir -p "${xdg}/containers"; cp /tmp/oc-mirror-pull-secret.json "${xdg}/containers/auth.json"'
echo "Pull secret installed to bastion auth location."

# Write the ImageSetConfiguration on the bastion.
# (same ISC as to-disk; oc-mirror needs it in disk-to-mirror mode)
ISC_PATH="${BASTION_WORKSPACE_PATH}/image-set-config.yaml"
# shellcheck disable=SC2087  # Intentionally unquoted: variable must expand client-side before SSH
ssh ${SSH_OPTS} "${BASTION_SSH_USER}@${BASTION_IP}" "cat > '${ISC_PATH}'" <<EOF
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  platform:
    release: ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}
EOF
echo "ImageSetConfiguration written on bastion at ${ISC_PATH}"

# ---------------------------------------------------------------------------
# VPC CIDR — read from vpc_info.json (written by aws-provision-vpc-disconnected).
# Scopes the firewall exemption to the actual provisioned VPC CIDR rather than
# assuming all of 10.0.0.0/8.
# ---------------------------------------------------------------------------
VPC_IPV4_CIDR="10.0.0.0/8"   # safe fallback if vpc_info.json is absent
VPC_IPV6_CIDR=""
if [[ -f "${SHARED_DIR}/vpc_info.json" ]]; then
    _cidr=$(jq -r '.vpc_ipv4_cidr // empty' "${SHARED_DIR}/vpc_info.json")
    [[ -n "${_cidr}" ]] && VPC_IPV4_CIDR="${_cidr}"
    _cidr6=$(jq -r '.vpc_ipv6_cidr // empty' "${SHARED_DIR}/vpc_info.json")
    [[ -n "${_cidr6}" ]] && VPC_IPV6_CIDR="${_cidr6}"
fi
echo "VPC IPv4 CIDR: ${VPC_IPV4_CIDR}"
echo "VPC IPv6 CIDR: ${VPC_IPV6_CIDR:-none}"

# ---------------------------------------------------------------------------
# Build and transfer the remote D2M script.
#
# All isolation, acceptance test, and disk-to-mirror logic runs as a single
# script on the bastion so that the EXIT trap covers every failure path.
#
# Client-side variables are interpolated here (before the file is transferred);
# bastion-local variables use escaped \${ } so they expand only on the bastion.
#
# Phases executed by the remote script:
#   1. Save iptables state (IPv4 + IPv6)
#   2. Register EXIT trap that restores firewall, cleans /etc/hosts, removes auth,
#      and collects the D2M log
#   3. Add /etc/hosts entry to route registry hostname to private IP
#   4. Apply IPv4 isolation via a dedicated OC_MIRROR_EGRESS chain (jumped from
#      the start of OUTPUT so pre-existing ACCEPT rules can't bypass it).
#      SSH_CONNECTION is used to derive the CI pod's IP and port so an explicit
#      ACCEPT rule pins the SSH return flow before the terminal REJECT.
#      Terminal rule uses REJECT (not DROP) so unexpected external connections
#      fail immediately rather than hanging until TCP timeout.
#   5. Apply IPv6 isolation via OC_MIRROR_EGRESS6 chain (same REJECT approach)
#   6. Isolation acceptance test:
#      a. Direct (--noproxy) connection to quay.io must fail
#      b. Direct connection to the registry hostname:port must succeed
#      c. REJECT rule must be present in both chains
#   7. Run oc-mirror disk-to-mirror under timeout, tee-ing output to /var/tmp
#      so it is recoverable even if the SSH session is disrupted
#   EXIT trap fires: restores firewall, removes /etc/hosts entry, auth file
# ---------------------------------------------------------------------------
REMOTE_D2M_SCRIPT="/tmp/oc-mirror-d2m.sh"

# Read the signature-ignore decision made by the to-disk step.
# oc-mirror re-validates signatures from the archive during disk-to-mirror, so
# the same flag must be passed in both phases for unsigned nightly/CI payloads.
IGNORE_RELEASE_SIGNATURE="false"
if [[ -f "${SHARED_DIR}/oc-mirror-ignore-release-signature" ]]; then
    IGNORE_RELEASE_SIGNATURE=$(cat "${SHARED_DIR}/oc-mirror-ignore-release-signature")
fi
echo "IGNORE_RELEASE_SIGNATURE=${IGNORE_RELEASE_SIGNATURE}"

# Write the remote script to a local temp file so we can use normal heredoc
# quoting: double-quoted lines interpolate client-side vars; single-quoted
# heredoc delimiters (<<'PART2') mean everything inside is literal bash
# for the bastion.
local_script=$(mktemp)

# Part 1: values that must be set from the client side
cat >> "${local_script}" <<PART1
#!/bin/bash
set -euo pipefail

MIRROR_REGISTRY_HOSTNAME="${MIRROR_REGISTRY_HOSTNAME}"
MIRROR_REGISTRY_PORT="${MIRROR_REGISTRY_PORT}"
MIRROR_REGISTRY_HOST="${MIRROR_REGISTRY_HOST}"
BASTION_PRIVATE_IP="${BASTION_PRIVATE_IP}"
ISC_PATH="${ISC_PATH}"
BASTION_WORKSPACE_PATH="${BASTION_WORKSPACE_PATH}"
BASTION_BIN_PATH="${BASTION_BIN_PATH}"
VPC_IPV4_CIDR="${VPC_IPV4_CIDR}"
VPC_IPV6_CIDR="${VPC_IPV6_CIDR}"
IGNORE_RELEASE_SIGNATURE="${IGNORE_RELEASE_SIGNATURE}"

PART1

# Part 2: the bastion-local logic (no client-side expansion needed)
cat >> "${local_script}" <<'PART2'
# -------------------------------------------------------------------
# EXIT trap — restores firewall, removes /etc/hosts entry and auth file.
# Runs unconditionally on exit, whether the D2M succeeds or fails.
# -------------------------------------------------------------------
function d2m_cleanup() {
    echo "=== [cleanup] Restoring iptables/ip6tables rules ==="
    if [[ -f /tmp/iptables-before-import.rules ]]; then
        sudo iptables-restore  < /tmp/iptables-before-import.rules  && echo "[cleanup] IPv4 rules restored." || echo "[cleanup] WARNING: IPv4 restore failed."
    fi
    if [[ -f /tmp/ip6tables-before-import.rules ]]; then
        sudo ip6tables-restore < /tmp/ip6tables-before-import.rules && echo "[cleanup] IPv6 rules restored." || echo "[cleanup] WARNING: IPv6 restore failed."
    fi
    echo "=== [cleanup] Removing /etc/hosts registry entry ==="
    sudo sed -i "/${MIRROR_REGISTRY_HOSTNAME}/d" /etc/hosts && echo "[cleanup] /etc/hosts entry removed." || echo "[cleanup] WARNING: /etc/hosts sed failed."
    echo "=== [cleanup] Removing remote auth file ==="
    xdg="${XDG_RUNTIME_DIR:-${HOME}/run}"
    rm -f /tmp/oc-mirror-pull-secret.json "${xdg}/containers/auth.json"
    echo "=== [cleanup] Done ==="
}
trap d2m_cleanup EXIT

# -------------------------------------------------------------------
# Save current firewall state before any modifications
# -------------------------------------------------------------------
echo "Saving current iptables/ip6tables rules..."
sudo iptables-save  > /tmp/iptables-before-import.rules
sudo ip6tables-save > /tmp/ip6tables-before-import.rules

# -------------------------------------------------------------------
# Registry routing: map public DNS name to bastion private IP.
# After isolation the public DNS may resolve to a public IP that is
# blocked.  This ensures oc-mirror reaches the registry over the
# VPC-internal path while still using the correct hostname for TLS.
# -------------------------------------------------------------------
echo "=== Adding /etc/hosts entry for registry routing ==="
echo "${BASTION_PRIVATE_IP} ${MIRROR_REGISTRY_HOSTNAME}" | sudo tee -a /etc/hosts
echo "/etc/hosts updated."

# -------------------------------------------------------------------
# IPv4 isolation via a dedicated chain jumped from the start of OUTPUT.
# Using a dedicated chain means pre-existing broad ACCEPT rules can't
# bypass the terminal REJECT.
#
# SSH_CONNECTION on the bastion is set by sshd to:
#   "<client-ip> <client-port> <server-ip> <server-port>"
# We use it to pin an explicit ACCEPT for the return flow of the CI pod's
# SSH control connection before applying the terminal REJECT.  Without this
# explicit rule the DROP/REJECT catches the SSH server's reply packets and
# the remote script's output is silently lost, causing an apparent 2-hour
# timeout.
# -------------------------------------------------------------------
echo "=== Applying IPv4 isolation ==="
read -r _ci_ip _ci_port _srv_ip _ssh_port <<<"${SSH_CONNECTION:-}"
sudo iptables -N OC_MIRROR_EGRESS 2>/dev/null || sudo iptables -F OC_MIRROR_EGRESS
sudo iptables -A OC_MIRROR_EGRESS -o lo                                            -j ACCEPT
sudo iptables -A OC_MIRROR_EGRESS -m state --state ESTABLISHED,RELATED             -j ACCEPT
sudo iptables -A OC_MIRROR_EGRESS -d "${VPC_IPV4_CIDR}"                            -j ACCEPT
sudo iptables -A OC_MIRROR_EGRESS -d 169.254.169.254/32                            -j ACCEPT
# Explicit SSH return-flow pinhole: allow TCP replies from sshd back to the CI pod.
if [[ -n "${_ci_ip:-}" && -n "${_ci_port:-}" && -n "${_ssh_port:-}" ]]; then
    echo "Pinning SSH return flow: src-port ${_ssh_port} -> ${_ci_ip}:${_ci_port}"
    sudo iptables -A OC_MIRROR_EGRESS \
        -p tcp -d "${_ci_ip}" --sport "${_ssh_port}" --dport "${_ci_port}" -j ACCEPT
else
    echo "WARNING: SSH_CONNECTION not set — SSH return-flow pinhole skipped"
fi
# REJECT (not DROP) so unexpected external deps fail immediately, not after TCP timeout.
sudo iptables -A OC_MIRROR_EGRESS                                                  -j REJECT --reject-with icmp-admin-prohibited
# Insert at the start of OUTPUT — takes precedence over existing rules.
sudo iptables -I OUTPUT 1 -j OC_MIRROR_EGRESS

# -------------------------------------------------------------------
# IPv6 isolation
# -------------------------------------------------------------------
echo "=== Applying IPv6 isolation ==="
sudo ip6tables -N OC_MIRROR_EGRESS6 2>/dev/null || sudo ip6tables -F OC_MIRROR_EGRESS6
sudo ip6tables -A OC_MIRROR_EGRESS6 -o lo                          -j ACCEPT
sudo ip6tables -A OC_MIRROR_EGRESS6 -m state --state ESTABLISHED,RELATED -j ACCEPT
# Link-local addresses required for neighbour discovery
sudo ip6tables -A OC_MIRROR_EGRESS6 -d fe80::/10                   -j ACCEPT
if [[ -n "${VPC_IPV6_CIDR}" ]]; then
    sudo ip6tables -A OC_MIRROR_EGRESS6 -d "${VPC_IPV6_CIDR}"      -j ACCEPT
fi
sudo ip6tables -A OC_MIRROR_EGRESS6                                 -j REJECT --reject-with icmp6-adm-prohibited
sudo ip6tables -I OUTPUT 1 -j OC_MIRROR_EGRESS6

echo "Isolation rules applied."
echo "IPv4 OC_MIRROR_EGRESS chain:"
sudo iptables  -L OC_MIRROR_EGRESS  -n -v
echo "IPv6 OC_MIRROR_EGRESS6 chain:"
sudo ip6tables -L OC_MIRROR_EGRESS6 -n -v

# -------------------------------------------------------------------
# Isolation acceptance test
# -------------------------------------------------------------------
echo "=== Isolation acceptance test ==="

echo "--- Test 1: direct connection to public internet must be blocked ---"
if curl --noproxy '*' -m 10 --silent --output /dev/null https://quay.io; then
    echo "FAIL: quay.io is reachable — isolation is broken"
    exit 1
else
    echo "PASS: quay.io not reachable (internet blocked)"
fi

echo "--- Test 2: registry must be reachable at the exact endpoint oc-mirror will use ---"
if curl --noproxy '*' -m 10 --silent --output /dev/null --insecure \
        "https://${MIRROR_REGISTRY_HOSTNAME}:${MIRROR_REGISTRY_PORT}"; then
    echo "PASS: registry at ${MIRROR_REGISTRY_HOST} reachable via private IP"
else
    echo "FAIL: registry at ${MIRROR_REGISTRY_HOST} not reachable"
    exit 1
fi

echo "--- Test 3: REJECT rules present in isolation chains ---"
if ! sudo iptables  -L OC_MIRROR_EGRESS  -n | grep -q REJECT; then
    echo "FAIL: REJECT rule missing from IPv4 OC_MIRROR_EGRESS chain"
    exit 1
fi
if ! sudo ip6tables -L OC_MIRROR_EGRESS6 -n | grep -q REJECT; then
    echo "FAIL: REJECT rule missing from IPv6 OC_MIRROR_EGRESS6 chain"
    exit 1
fi
echo "PASS: REJECT rules present in both isolation chains"
echo "Isolation acceptance test passed."

# -------------------------------------------------------------------
# Disk-to-mirror (Phase 2)
# -------------------------------------------------------------------
echo "=== Running oc-mirror disk-to-mirror ==="
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-${HOME}/run}"
export REGISTRY_AUTH_PREFERENCE=podman

# ref OCPBUGS-56009: apply --ignore-release-signature when the to-disk step
# determined the payload is unsigned (e.g. nightly/CI builds).
# --ignore-release-signature is release-specific; it does not suppress
# signature checks for other image types such as operator bundles.
OC_MIRROR_EXTRA_FLAGS=""
if [[ "${IGNORE_RELEASE_SIGNATURE}" == "true" ]]; then
    OC_MIRROR_EXTRA_FLAGS="--ignore-release-signature"
    echo "Applying --ignore-release-signature (payload is unsigned)"
fi

# Run D2M under a 100-minute timeout and tee output to /var/tmp so it is
# preserved even if the SSH session is disrupted by firewall rules.
# The step grace_period is 15 m and the step timeout is 2 h, so 100 m gives
# ample room for the EXIT trap cleanup to complete before ci-operator kills us.
D2M_LOG="/var/tmp/oc-mirror-d2m.log"
timeout 6000 "${BASTION_BIN_PATH}" -c "${ISC_PATH}" \
    --from "file://${BASTION_WORKSPACE_PATH}" \
    "docker://${MIRROR_REGISTRY_HOST}" \
    --dest-tls-verify=false --v2 ${OC_MIRROR_EXTRA_FLAGS} \
    2>&1 | tee "${D2M_LOG}"
# Capture the exit status of oc-mirror (not tee).
D2M_RC=${PIPESTATUS[0]}
if [[ ${D2M_RC} -ne 0 ]]; then
    echo "ERROR: oc-mirror disk-to-mirror exited with code ${D2M_RC}"
    exit ${D2M_RC}
fi

echo "=== oc-mirror disk-to-mirror complete ==="
# EXIT trap fires here: restores firewall, removes /etc/hosts entry and auth file.
PART2

# Transfer and execute the remote script
scp ${SSH_OPTS} "${local_script}" "${BASTION_SSH_USER}@${BASTION_IP}:${REMOTE_D2M_SCRIPT}"
ssh ${SSH_OPTS} "${BASTION_SSH_USER}@${BASTION_IP}" "chmod +x '${REMOTE_D2M_SCRIPT}'"
rm -f "${local_script}"

echo "=== Executing remote D2M script on bastion ==="
ssh ${SSH_OPTS} "${BASTION_SSH_USER}@${BASTION_IP}" "${REMOTE_D2M_SCRIPT}"
echo "Remote D2M script complete."

# Collect the D2M log from the bastion.  The log is written to /var/tmp on the
# bastion so it survives even if the SSH session was disrupted during isolation.
# Run this after firewall restoration so the scp is not blocked.
D2M_LOG="/var/tmp/oc-mirror-d2m.log"
scp ${SSH_OPTS} "${BASTION_SSH_USER}@${BASTION_IP}:${D2M_LOG}" \
    "${ARTIFACT_DIR}/bastion-oc-mirror-d2m.log" 2>/dev/null || \
    echo "Note: D2M log not found on bastion at ${D2M_LOG} (may not have been created)"

# Save post-restore iptables state to artifacts for audit/debugging
ssh ${SSH_OPTS} "${BASTION_SSH_USER}@${BASTION_IP}" \
    "sudo iptables -L -n -v && echo '---IPv6---' && sudo ip6tables -L -n -v" \
    > "${ARTIFACT_DIR}/bastion-iptables-post-restore.txt" 2>&1 || true

# ---------------------------------------------------------------------------
# Copy IDMS/ITMS from bastion to SHARED_DIR
# disk-to-mirror writes cluster-resources under the workspace working-dir.
# The subsequent mirror-images-by-oc-mirror-conf-mirror step reads these files.
# ---------------------------------------------------------------------------
echo "=== Copying IDMS/ITMS from bastion to SHARED_DIR ==="
BASTION_CLUSTER_RESOURCES="${BASTION_WORKSPACE_PATH}/working-dir/cluster-resources"

idms_remote="${BASTION_CLUSTER_RESOURCES}/idms-oc-mirror.yaml"
idms_local="/tmp/idms-oc-mirror.yaml"

ssh ${SSH_OPTS} "${BASTION_SSH_USER}@${BASTION_IP}" \
    "test -s '${idms_remote}' || { echo 'ERROR: idms-oc-mirror.yaml not found at ${idms_remote}'; ls -la '${BASTION_CLUSTER_RESOURCES}/' 2>/dev/null || true; exit 1; }"

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
