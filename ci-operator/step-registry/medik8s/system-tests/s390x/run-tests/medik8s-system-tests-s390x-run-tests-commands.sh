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

# system-tests StopKubeletSSH calls ssh(1) to node InternalIPs. On libvirt OZ
# those IPs are unreachable from the CI pod. We port-forward the in-cluster
# hostNetwork ssh-bastion and force every ssh(1) through it with a PATH wrapper
# (previous ~/.ssh/config Host wildcards were not applied — ssh dialed nodes
# directly and timed out).
cleanup_ssh_bastion_proxy() {
  local sup_pid pf_pid
  # The supervised port-forward loop must die when tests finish; otherwise
  # entrypoint sees an open log pipe and waits until the 3h step timeout
  # (SNR green suites have already failed this way).
  touch /tmp/ssh-bastion-port-forward.stop
  if [[ -f /tmp/ssh-bastion-port-forward.pid ]]; then
    pf_pid="$(cat /tmp/ssh-bastion-port-forward.pid 2>/dev/null || true)"
    if [[ -n "${pf_pid}" ]]; then
      kill "${pf_pid}" 2>/dev/null || true
    fi
  fi
  if [[ -f /tmp/ssh-bastion-port-forward-supervisor.pid ]]; then
    sup_pid="$(cat /tmp/ssh-bastion-port-forward-supervisor.pid 2>/dev/null || true)"
    if [[ -n "${sup_pid}" ]]; then
      kill "${sup_pid}" 2>/dev/null || true
      wait "${sup_pid}" 2>/dev/null || true
    fi
  fi
  pkill -f 'port-forward svc/ssh-bastion' 2>/dev/null || true
  rm -f /tmp/ssh-bastion-port-forward.pid \
    /tmp/ssh-bastion-port-forward-supervisor.pid \
    /tmp/ssh-bastion-port-forward.stop
}
trap cleanup_ssh_bastion_proxy EXIT

setup_ssh_bastion_proxy() {
  local mode host port bastion_key_src bastion_key_dst worker_key_src worker_key_dst wrapper_dir

  if [[ ! -f "${SHARED_DIR}/medik8s_ssh_bastion_mode" ]]; then
    echo "No ssh-bastion marker in SHARED_DIR; skipping SSH proxy setup"
    return 0
  fi

  if ! oc get svc -n test-ssh-bastion ssh-bastion &>/dev/null; then
    echo "WARNING: medik8s_ssh_bastion_mode set but svc/ssh-bastion missing" >&2
    return 0
  fi

  mode="$(cat "${SHARED_DIR}/medik8s_ssh_bastion_mode")"
  # Bastion hop: dedicated key from ssh-bastion step (falls back to cluster key).
  bastion_key_src="${SHARED_DIR}/medik8s_bastion_ssh_key"
  if [[ ! -f "${bastion_key_src}" ]]; then
    bastion_key_src="${CLUSTER_PROFILE_DIR}/ssh-privatekey"
  fi
  # Worker hop: cluster install key (present in node authorized_keys).
  worker_key_src="${CLUSTER_PROFILE_DIR}/ssh-privatekey"
  if [[ ! -f "${bastion_key_src}" ]]; then
    echo "ERROR: bastion SSH private key not found at ${bastion_key_src}" >&2
    return 1
  fi
  if [[ ! -f "${worker_key_src}" ]]; then
    echo "ERROR: worker SSH private key not found at ${worker_key_src}" >&2
    return 1
  fi

  export HOME="${HOME:-/tmp}"
  mkdir -p "${HOME}/.ssh"
  chmod 700 "${HOME}/.ssh"
  bastion_key_dst="${HOME}/.ssh/medik8s_bastion_key"
  worker_key_dst="${HOME}/.ssh/medik8s_worker_key"
  cp "${bastion_key_src}" "${bastion_key_dst}"
  cp "${worker_key_src}" "${worker_key_dst}"
  chmod 600 "${bastion_key_dst}" "${worker_key_dst}"

  host=""
  port=22
  case "${mode}" in
    lb-hostname|lb-ip)
      host="$(cat "${SHARED_DIR}/medik8s_ssh_bastion_host")"
      ;;
    port-forward)
      host="127.0.0.1"
      port=12222
      # Supervisor: restart port-forward if it dies (API blip, bastion
      # reschedule). Fully detach stdio so entrypoint does not wait on us.
      # Stop via /tmp/ssh-bastion-port-forward.stop from EXIT trap.
      rm -f /tmp/ssh-bastion-port-forward.stop
      (
        attempt=0
        while [[ ! -f /tmp/ssh-bastion-port-forward.stop ]]; do
          attempt=$((attempt + 1))
          echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) starting oc port-forward attempt=${attempt}"
          oc -n test-ssh-bastion port-forward svc/ssh-bastion "${port}:22" &
          pf_pid=$!
          echo "${pf_pid}" > /tmp/ssh-bastion-port-forward.pid
          wait "${pf_pid}" || true
          [[ -f /tmp/ssh-bastion-port-forward.stop ]] && break
          echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) port-forward exited; restarting in 2s"
          sleep 2
        done
        echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) port-forward supervisor stopped"
      ) >>"${ARTIFACT_DIR}/ssh-bastion-port-forward.log" 2>&1 </dev/null &
      echo $! > /tmp/ssh-bastion-port-forward-supervisor.pid
      for _ in $(seq 1 90); do
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
      echo "SSH bastion port-forward ready on localhost:${port} (supervised restart enabled)"
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

  wrapper_dir="$(mktemp -d)"
  # Bake bastion coordinates into the wrapper so Go subprocesses do not depend
  # on exported env. Inner hop uses /usr/bin/ssh (not this wrapper).
  # ProxyCommand authenticates to bastion with BASTION_KEY; outer -i uses
  # WORKER_KEY for core@node (cluster install key).
  cat > "${wrapper_dir}/ssh" <<EOF
#!/bin/bash
set -euo pipefail
REAL_SSH=/usr/bin/ssh
BASTION_HOST=${host}
BASTION_PORT=${port}
BASTION_KEY=${bastion_key_dst}
WORKER_KEY=${worker_key_dst}
# Do not re-proxy if caller already set ProxyCommand (or nested hop).
if [[ "\$*" == *ProxyCommand* ]]; then
  exec "\${REAL_SSH}" "\$@"
fi
exec "\${REAL_SSH}" \\
  -o "ProxyCommand=\${REAL_SSH} -p \${BASTION_PORT} -i \${BASTION_KEY} -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -W %h:%p core@\${BASTION_HOST}" \\
  -i "\${WORKER_KEY}" \\
  -o BatchMode=yes \\
  -o StrictHostKeyChecking=no \\
  -o UserKnownHostsFile=/dev/null \\
  "\$@"
EOF
  chmod 755 "${wrapper_dir}/ssh"
  export PATH="${wrapper_dir}:${PATH}"

  echo "SSH bastion proxy configured: mode=${mode} host=${host} port=${port} wrapper=$(command -v ssh)"
  echo "Bastion key: ${bastion_key_src}  Worker key: ${worker_key_src}"

  local worker_ip
  worker_ip="$(oc get nodes -l node-role.kubernetes.io/worker= -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"
  if [[ -n "${worker_ip}" ]]; then
    echo "Verifying SSH via bastion to worker InternalIP ${worker_ip}..."
    if ! ssh -o ConnectTimeout=20 "core@${worker_ip}" 'hostname; systemctl is-active kubelet'; then
      echo "ERROR: bastion-proxied SSH to ${worker_ip} failed; kubelet-stop tests will fail" >&2
      echo "--- port-forward log ---" >&2
      cat "${ARTIFACT_DIR}/ssh-bastion-port-forward.log" >&2 || true
      echo "--- direct bastion login test ---" >&2
      /usr/bin/ssh -vvv -p "${port}" -i "${bastion_key_dst}" \
        -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 "core@${host}" 'echo bastion-ok; id -un' >&2 || true
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
