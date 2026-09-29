#!/bin/bash

set -euo pipefail

if [[ -f "${SHARED_DIR}/workload_image" ]]; then
  export WORKLOAD_IMAGE
  WORKLOAD_IMAGE="$(cat "${SHARED_DIR}/workload_image")"
fi

echo "=== medik8s system-tests s390x OZ ==="
echo "ECO_TEST_FEATURES: ${ECO_TEST_FEATURES:-<unset>}"
echo "ECO_TEST_LABELS: ${ECO_TEST_LABELS:-<none>}"
echo "ECO_TEST_TIMEOUT: ${ECO_TEST_TIMEOUT:-1h}"
echo "WORKLOAD_IMAGE: ${WORKLOAD_IMAGE:-<unset>}"

if [[ -z "${ECO_TEST_FEATURES:-}" ]]; then
  echo "ERROR: ECO_TEST_FEATURES is required" >&2
  exit 1
fi

# system-tests StopKubeletSSH / StartKubeletSSH call ssh(1) to node InternalIPs.
# On AWS, findSSHBastion() picks up the LB hostname. On libvirt OZ there is no
# cloud LB and node IPs are not reachable from the CI pod, so we:
#   1) port-forward the in-cluster eparis ssh-bastion Service, and
#   2) install an SSH config ProxyCommand for RFC1918 destinations.
# Command-line ProxyCommand from findSSHBastion (AWS) still wins when set.
setup_ssh_bastion_proxy() {
  local mode host port key_src key_dst

  if [[ ! -f "${SHARED_DIR}/medik8s_ssh_bastion_mode" ]]; then
    echo "No ssh-bastion marker in SHARED_DIR; skipping SSH proxy setup"
    return 0
  fi

  if ! oc get svc -n test-ssh-bastion ssh-bastion &>/dev/null; then
    echo "WARNING: medik8s_ssh_bastion_mode set but svc/ssh-bastion missing" >&2
    return 0
  fi

  mode="$(cat "${SHARED_DIR}/medik8s_ssh_bastion_mode")"
  key_src="${CLUSTER_PROFILE_DIR}/ssh-privatekey"
  if [[ ! -f "${key_src}" ]]; then
    echo "ERROR: SSH private key not found at ${key_src}" >&2
    return 1
  fi

  mkdir -p "${HOME}/.ssh"
  chmod 700 "${HOME}/.ssh"
  key_dst="${HOME}/.ssh/medik8s_bastion_key"
  cp "${key_src}" "${key_dst}"
  chmod 600 "${key_dst}"

  host=""
  port=22
  case "${mode}" in
    lb-hostname|lb-ip)
      host="$(cat "${SHARED_DIR}/medik8s_ssh_bastion_host")"
      ;;
    port-forward)
      host="127.0.0.1"
      port=12222
      echo "Starting oc port-forward for ssh-bastion on localhost:${port}"
      oc -n test-ssh-bastion port-forward svc/ssh-bastion "${port}:22" \
        >"${ARTIFACT_DIR}/ssh-bastion-port-forward.log" 2>&1 &
      echo $! > /tmp/ssh-bastion-port-forward.pid
      # Wait until the local port accepts connections.
      for _ in $(seq 1 60); do
        if (echo >/dev/tcp/127.0.0.1/"${port}") >/dev/null 2>&1; then
          break
        fi
        sleep 1
      done
      if ! (echo >/dev/tcp/127.0.0.1/"${port}") >/dev/null 2>&1; then
        echo "ERROR: ssh-bastion port-forward did not become ready on :${port}" >&2
        cat "${ARTIFACT_DIR}/ssh-bastion-port-forward.log" >&2 || true
        return 1
      fi
      ;;
    *)
      echo "WARNING: unknown medik8s_ssh_bastion_mode=${mode}; skipping SSH proxy" >&2
      return 0
      ;;
  esac

  if [[ -z "${host}" ]]; then
    echo "WARNING: empty bastion host for mode=${mode}; skipping SSH proxy" >&2
    return 0
  fi

  # Cover common libvirt / OVN machine and service CIDRs used as node InternalIPs.
  cat > "${HOME}/.ssh/config" <<EOF
Host 10.* 192.168.* 172.16.* 172.17.* 172.18.* 172.19.* 172.20.* 172.21.* 172.22.* 172.23.* 172.24.* 172.25.* 172.26.* 172.27.* 172.28.* 172.29.* 172.30.* 172.31.*
  ProxyCommand /usr/bin/ssh -p ${port} -i ${key_dst} -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -W %h:%p core@${host}
  IdentityFile ${key_dst}
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  BatchMode yes
EOF
  chmod 600 "${HOME}/.ssh/config"
  export SSH_BASTION_HOST="${host}"
  export SSH_BASTION_PORT="${port}"
  echo "SSH bastion proxy configured: mode=${mode} host=${host} port=${port}"

  # Prove kubelet-stop path works before spending hours in Ginkgo.
  local worker_ip
  worker_ip="$(oc get nodes -l node-role.kubernetes.io/worker= -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"
  if [[ -n "${worker_ip}" ]]; then
    echo "Verifying SSH via bastion to worker InternalIP ${worker_ip}..."
    if ! ssh -o ConnectTimeout=15 "core@${worker_ip}" 'hostname; systemctl is-active kubelet'; then
      echo "ERROR: bastion-proxied SSH to ${worker_ip} failed; kubelet-stop tests will fail" >&2
      return 1
    fi
    echo "Bastion SSH verification succeeded"
  else
    echo "WARNING: no worker InternalIP found for SSH verification" >&2
  fi
}

setup_ssh_bastion_proxy

echo "=== Operator status before tests ==="
oc get csv,subscription,pods -n openshift-workload-availability -o wide || true

make run-tests

echo "=== system-tests complete ==="
