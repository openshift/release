#!/bin/bash
# Gated SSH jump setup for medik8s system-tests on s390x libvirt OZ.
#
# quay.io/eparis/ssh is amd64-only, and the CI pod cannot reach node machine
# addresses used by kubelet-stop tests. Instead of deploying a custom sshd
# workload, start a long-lived `oc debug` session on a control-plane node and
# record it in SHARED_DIR. run-tests then wraps ssh(1) with ProxyCommand that
# relays TCP through that jump (host path via chroot /host).
#
# This avoids shipping a Deployment that requests elevated container privileges
# in the step registry.

set -euo pipefail

if [[ "${MEDIK8S_S390X_SSH_BASTION:-false}" != "true" ]]; then
  echo "MEDIK8S_S390X_SSH_BASTION is not true; skipping ssh jump setup"
  exit 0
fi

echo "=== Preparing SSH jump for medik8s system-tests (oc debug) ==="

if ! whoami &>/dev/null; then
  if [[ -w /etc/passwd ]]; then
    echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
  else
    echo "/etc/passwd is not writeable, and user matching this uid is not found." >&2
    exit 1
  fi
fi

# shellcheck disable=SC1090
if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

# This step runs from upi-installer; use the image's oc (no external download).
if ! command -v oc >/dev/null 2>&1; then
  echo "ERROR: oc not found in PATH" >&2
  exit 1
fi
oc version --client >/dev/null

SSH_BASTION_NAMESPACE=test-ssh-bastion
SSH_PUB_KEY_FILE="${CLUSTER_PROFILE_DIR}/ssh-publickey"
SSH_PRIV_KEY_FILE="${CLUSTER_PROFILE_DIR}/ssh-privatekey"
if [[ ! -f "${SSH_PRIV_KEY_FILE}" ]]; then
  echo "ERROR: cluster SSH private key not found" >&2
  exit 1
fi
if [[ ! -f "${SSH_PUB_KEY_FILE}" ]]; then
  echo "ERROR: cluster SSH public key not found" >&2
  exit 1
fi

cp "${SSH_PRIV_KEY_FILE}" "${SHARED_DIR}/medik8s_bastion_ssh_key"
chmod 600 "${SHARED_DIR}/medik8s_bastion_ssh_key"
echo "Cluster SSH key fingerprint: $(ssh-keygen -lf "${SSH_PUB_KEY_FILE}" | awk '{print $2}')"

echo "Creating namespace ${SSH_BASTION_NAMESPACE}..."
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${SSH_BASTION_NAMESPACE}
EOF

# Prefer a control-plane node that SNR/NHC are less likely to remediate first.
pick_jump_node() {
  local n
  for n in control-2 control-1 control-0; do
    if oc get "node/${n}" &>/dev/null; then
      echo "${n}"
      return 0
    fi
  done
  oc get nodes -l node-role.kubernetes.io/master -o jsonpath='{.items[0].metadata.name}'
}

jump_node="$(pick_jump_node)"
if [[ -z "${jump_node}" ]]; then
  echo "ERROR: no control-plane node available for SSH jump" >&2
  exit 1
fi

# Tear down any previous jump pod in this namespace (rehearse retries).
oc -n "${SSH_BASTION_NAMESPACE}" delete pod --all --wait=false --ignore-not-found >/dev/null 2>&1 || true

echo "Starting oc debug jump session on a control-plane node..."
# oc debug creates the temporary privileged pod; we do not apply such a
# Deployment from this repository.
oc debug "node/${jump_node}" \
  --to-namespace="${SSH_BASTION_NAMESPACE}" \
  --quiet \
  -- sleep infinity >/dev/null 2>&1 &
debug_pid=$!

cleanup_failed_start() {
  kill "${debug_pid}" 2>/dev/null || true
  oc -n "${SSH_BASTION_NAMESPACE}" delete pod --all --wait=false --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup_failed_start EXIT

jump_pod=""
for _ in $(seq 1 90); do
  if ! kill -0 "${debug_pid}" 2>/dev/null; then
    echo "ERROR: oc debug jump process exited early" >&2
    exit 1
  fi
  jump_pod="$(oc -n "${SSH_BASTION_NAMESPACE}" get pods \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "${jump_pod}" ]]; then
    if oc -n "${SSH_BASTION_NAMESPACE}" exec "${jump_pod}" -- \
        chroot /host /bin/bash -c 'test -r /bin/bash' >/dev/null 2>&1; then
      break
    fi
  fi
  jump_pod=""
  sleep 2
done

if [[ -z "${jump_pod}" ]]; then
  echo "ERROR: SSH jump pod did not become Running" >&2
  exit 1
fi

# Connectivity check without printing addresses or node names.
worker_ip="$(oc get nodes -l node-role.kubernetes.io/worker= \
  -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"
if [[ -z "${worker_ip}" ]]; then
  echo "ERROR: could not resolve a worker address for jump verification" >&2
  exit 1
fi
if ! oc -n "${SSH_BASTION_NAMESPACE}" exec "${jump_pod}" -- \
    chroot /host /bin/bash -c "timeout 10 bash -c 'echo >/dev/tcp/${worker_ip}/22'" >/dev/null 2>&1; then
  echo "ERROR: jump host cannot reach worker SSH port" >&2
  exit 1
fi
echo "Jump host to worker SSH port check succeeded"

# Prove node SSH via the same ProxyCommand path run-tests will use (no host/IP logs).
export HOME="${HOME:-/tmp}"
mkdir -p "${HOME}/.ssh"
chmod 700 "${HOME}/.ssh"
key_dst="${HOME}/.ssh/medik8s_verify_key"
cp "${SHARED_DIR}/medik8s_bastion_ssh_key" "${key_dst}"
chmod 600 "${key_dst}"

proxy_cmd="oc -n ${SSH_BASTION_NAMESPACE} exec -i ${jump_pod} -- chroot /host /bin/bash -c 'exec 3<>/dev/tcp/%h/%p; cat <&3 & cat >&3; wait'"
if ! ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=20 \
    -o "ProxyCommand=${proxy_cmd}" \
    -i "${key_dst}" \
    "core@${worker_ip}" 'systemctl is-active kubelet' >/dev/null; then
  echo "ERROR: SSH via oc-debug jump failed; kubelet-stop tests will fail" >&2
  exit 1
fi
echo "SSH via oc-debug jump verification succeeded"

# Keep the background oc debug process for the job; clear failure trap.
trap - EXIT

echo "${jump_pod}" > "${SHARED_DIR}/medik8s_ssh_jump_pod"
echo "${SSH_BASTION_NAMESPACE}" > "${SHARED_DIR}/medik8s_ssh_jump_ns"
echo "${jump_node}" > "${SHARED_DIR}/medik8s_ssh_jump_node"
echo "oc-debug-jump" > "${SHARED_DIR}/medik8s_ssh_bastion_mode"
echo "=== ssh jump ready ==="
