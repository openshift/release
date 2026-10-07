#!/bin/bash
# Gated ssh-bastion for medik8s system-tests on s390x libvirt OZ.
#
# quay.io/eparis/ssh:latest is amd64-only. This step deploys openssh-server on
# multi-arch centos stream9 with hostNetwork so the bastion can reach node
# InternalIPs on the libvirt machine network (pod network cannot). sshd listens
# on 2222 to avoid clashing with the node's host sshd on :22. run-tests
# port-forwards the Service (libvirt has no cloud LB).
#
# Important: dnf install of openssh on s390x can take several minutes. The
# container must not be treated as Ready until sshd is listening on :2222.

set -euo pipefail

if [[ "${MEDIK8S_S390X_SSH_BASTION:-false}" != "true" ]]; then
  echo "MEDIK8S_S390X_SSH_BASTION is not true; skipping ssh-bastion setup"
  exit 0
fi

echo "=== Deploying s390x-capable ssh-bastion for medik8s system-tests ==="

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

mkdir -p /tmp/client
curl -L --fail https://openshift-mirror-list.ci-systems.workers.dev/pub/openshift-v4/clients/oc/latest/linux/oc.tar.gz \
  | tar --directory=/tmp/client -xzf -
PATH=/tmp/client:$PATH
oc version --client

SSH_BASTION_NAMESPACE=test-ssh-bastion
SSH_PUB_KEY_FILE="${CLUSTER_PROFILE_DIR}/ssh-publickey"
if [[ ! -f "${SSH_PUB_KEY_FILE}" ]]; then
  echo "ERROR: cluster SSH public key not found at ${SSH_PUB_KEY_FILE}" >&2
  exit 1
fi

# Dedicated bastion login key. Cluster-profile pub/priv pairs have been observed
# to fail bastion auth on this path (Permission denied) even when workers accept
# the same private key. Generate our own key for bastion login; keep the cluster
# pubkey too so either key can open the bastion. Worker hops still use the
# cluster private key (nodes are installed with that public key).
bastion_key_dir="$(mktemp -d)"
ssh-keygen -q -t ed25519 -f "${bastion_key_dir}/id_bastion" -C 'medik8s-s390x-bastion' -N ''
cat "${bastion_key_dir}/id_bastion.pub" "${SSH_PUB_KEY_FILE}" > "${bastion_key_dir}/authorized_keys"
cp "${bastion_key_dir}/id_bastion" "${SHARED_DIR}/medik8s_bastion_ssh_key"
chmod 600 "${SHARED_DIR}/medik8s_bastion_ssh_key"
echo "Bastion login key fingerprint: $(ssh-keygen -lf "${bastion_key_dir}/id_bastion.pub" | awk '{print $2}')"
echo "Cluster pubkey fingerprint:    $(ssh-keygen -lf "${SSH_PUB_KEY_FILE}" | awk '{print $2}')"

echo "Creating namespace ${SSH_BASTION_NAMESPACE}..."
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${SSH_BASTION_NAMESPACE}
  labels:
    openshift.io/run-level: "0"
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
    security.openshift.io/scc.podSecurityLabelSync: "false"
EOF

echo "Creating service account and privileged SCC binding..."
oc -n "${SSH_BASTION_NAMESPACE}" apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ssh-bastion
EOF
oc adm policy add-scc-to-user privileged -z ssh-bastion -n "${SSH_BASTION_NAMESPACE}"

echo "Generating ssh host keys and sshd_config (listen :2222 for hostNetwork)..."
workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}" "${bastion_key_dir}"' EXIT
ssh-keygen -q -t rsa -f "${workdir}/ssh_host_rsa_key" -C '' -N ''
ssh-keygen -q -t ecdsa -f "${workdir}/ssh_host_ecdsa_key" -C '' -N ''
ssh-keygen -q -t ed25519 -f "${workdir}/ssh_host_ed25519_key" -C '' -N ''
cat > "${workdir}/sshd_config" <<'EOF'
Port 2222
# Listen on both families so oc port-forward (often dials [::1]) works.
AddressFamily any
ListenAddress 0.0.0.0
ListenAddress ::
HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ecdsa_key
HostKey /etc/ssh/ssh_host_ed25519_key
SyslogFacility AUTHPRIV
PermitRootLogin no
PubkeyAuthentication yes
AuthorizedKeysFile /home/core/.ssh/authorized_keys
# Containerized sshd: avoid host-uid/home StrictModes rejections.
StrictModes no
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
X11Forwarding no
PrintMotd no
AllowTcpForwarding yes
GatewayPorts no
PermitTunnel no
Subsystem sftp /usr/libexec/openssh/sftp-server
EOF

oc -n "${SSH_BASTION_NAMESPACE}" delete secret ssh-host-keys --ignore-not-found
oc -n "${SSH_BASTION_NAMESPACE}" create secret generic ssh-host-keys \
  --from-file="ssh_host_rsa_key=${workdir}/ssh_host_rsa_key" \
  --from-file="ssh_host_ecdsa_key=${workdir}/ssh_host_ecdsa_key" \
  --from-file="ssh_host_ed25519_key=${workdir}/ssh_host_ed25519_key" \
  --from-file="sshd_config=${workdir}/sshd_config"

oc -n "${SSH_BASTION_NAMESPACE}" delete secret ssh-authorized-keys --ignore-not-found
oc -n "${SSH_BASTION_NAMESPACE}" create secret generic ssh-authorized-keys \
  --from-file="authorized_keys=${bastion_key_dir}/authorized_keys"

echo "Creating ClusterIP Service (forwards to hostNetwork sshd :2222)..."
oc -n "${SSH_BASTION_NAMESPACE}" apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  labels:
    run: ssh-bastion
  name: ssh-bastion
spec:
  ports:
  - name: ssh
    port: 22
    protocol: TCP
    targetPort: 2222
  selector:
    run: ssh-bastion
  type: ClusterIP
EOF

echo "Creating hostNetwork ssh-bastion Deployment (quay.io/centos/centos:stream9)..."
oc -n "${SSH_BASTION_NAMESPACE}" apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    run: ssh-bastion
  name: ssh-bastion
spec:
  replicas: 1
  # dnf install openssh on s390x is slow; default 600s is usually enough but
  # leave headroom so rollout does not time out mid-install.
  progressDeadlineSeconds: 900
  selector:
    matchLabels:
      run: ssh-bastion
  template:
    metadata:
      labels:
        run: ssh-bastion
    spec:
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      serviceAccountName: ssh-bastion
      containers:
      - name: ssh-bastion
        image: quay.io/centos/centos:stream9
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 2222
          hostPort: 2222
          name: ssh
          protocol: TCP
        securityContext:
          privileged: true
        # Do not mark Ready until sshd is listening. Without this, rollout
        # succeeds while dnf is still installing and port-forward gets
        # connection refused on :2222.
        startupProbe:
          tcpSocket:
            port: 2222
          periodSeconds: 5
          failureThreshold: 120
        readinessProbe:
          tcpSocket:
            port: 2222
          periodSeconds: 2
          failureThreshold: 3
        volumeMounts:
        - name: ssh-host-keys
          mountPath: /ssh-host-keys
          readOnly: true
        - name: ssh-authorized-keys
          mountPath: /ssh-authorized-keys
          readOnly: true
        command:
        - /bin/bash
        - -ec
        - |
          echo "Installing openssh-server on $(uname -m)..."
          dnf install -y --setopt=install_weak_deps=False openssh-server openssh-clients
          mkdir -p /var/run/sshd /var/empty/sshd
          cp /ssh-host-keys/ssh_host_rsa_key /ssh-host-keys/ssh_host_ecdsa_key \
            /ssh-host-keys/ssh_host_ed25519_key /ssh-host-keys/sshd_config /etc/ssh/
          chmod 600 /etc/ssh/ssh_host_*_key
          chmod 644 /etc/ssh/sshd_config
          id -u core >/dev/null 2>&1 || useradd -m -u 1000 core
          mkdir -p /home/core/.ssh
          cp /ssh-authorized-keys/authorized_keys /home/core/.ssh/authorized_keys
          chown -R core:core /home/core
          chmod 700 /home/core/.ssh
          chmod 600 /home/core/.ssh/authorized_keys
          /usr/sbin/sshd -t -f /etc/ssh/sshd_config
          echo "Starting sshd on :2222 (hostNetwork)..."
          exec /usr/sbin/sshd -D -e -f /etc/ssh/sshd_config
      volumes:
      - name: ssh-host-keys
        secret:
          secretName: ssh-host-keys
      - name: ssh-authorized-keys
        secret:
          secretName: ssh-authorized-keys
      restartPolicy: Always
EOF

dump_bastion_debug() {
  echo "=== ssh-bastion debug ===" >&2
  oc -n "${SSH_BASTION_NAMESPACE}" get pods,svc,deploy -o wide >&2 || true
  oc -n "${SSH_BASTION_NAMESPACE}" describe deploy/ssh-bastion >&2 || true
  oc -n "${SSH_BASTION_NAMESPACE}" get pods -l run=ssh-bastion -o name 2>/dev/null \
    | while read -r pod; do
        echo "--- describe ${pod} ---" >&2
        oc -n "${SSH_BASTION_NAMESPACE}" describe "${pod}" >&2 || true
        echo "--- logs ${pod} ---" >&2
        oc -n "${SSH_BASTION_NAMESPACE}" logs "${pod}" --tail=120 >&2 || true
      done
}

wait_for_sshd() {
  local bastion_pod="$1"
  local i
  echo "Waiting for sshd to listen on 127.0.0.1:2222 inside bastion (dnf install may take several minutes)..."
  for i in $(seq 1 120); do
    if oc -n "${SSH_BASTION_NAMESPACE}" exec "${bastion_pod}" -- \
        bash -c 'echo >/dev/tcp/127.0.0.1/2222' >/dev/null 2>&1; then
      echo "sshd is listening on :2222 (attempt ${i})"
      return 0
    fi
    if (( i % 6 == 0 )); then
      echo "still waiting for sshd... (${i}/120) last log lines:"
      oc -n "${SSH_BASTION_NAMESPACE}" logs "${bastion_pod}" --tail=5 2>/dev/null || true
    fi
    sleep 5
  done
  return 1
}

echo "Waiting for ssh-bastion deployment to become Available (sshd readiness)..."
if ! oc -n "${SSH_BASTION_NAMESPACE}" rollout status deployment/ssh-bastion --timeout=12m; then
  dump_bastion_debug
  exit 1
fi
oc -n "${SSH_BASTION_NAMESPACE}" get pods,svc -o wide

bastion_pod="$(oc -n "${SSH_BASTION_NAMESPACE}" get pods -l run=ssh-bastion -o jsonpath='{.items[0].metadata.name}')"
if ! wait_for_sshd "${bastion_pod}"; then
  echo "ERROR: sshd never became ready on :2222" >&2
  dump_bastion_debug
  exit 1
fi

echo "Installed authorized_keys fingerprints in bastion:"
oc -n "${SSH_BASTION_NAMESPACE}" exec "${bastion_pod}" -- \
  ssh-keygen -lf /home/core/.ssh/authorized_keys || true

# Prove the bastion pod can reach a worker on the machine network.
worker_ip="$(oc get nodes -l node-role.kubernetes.io/worker= -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"
if [[ -n "${worker_ip}" ]]; then
  echo "Checking bastion -> worker ${worker_ip}:22 connectivity from inside the bastion pod..."
  if ! oc -n "${SSH_BASTION_NAMESPACE}" exec "${bastion_pod}" -- \
      bash -c "timeout 10 bash -c 'echo >/dev/tcp/${worker_ip}/22'" 2>/dev/null; then
    echo "ERROR: bastion pod cannot TCP-connect to ${worker_ip}:22 (machine network unreachable)" >&2
    dump_bastion_debug
    exit 1
  fi
  echo "Bastion -> worker TCP check succeeded"
fi

# Prove bastion login works with the dedicated key (same path run-tests will use).
echo "Verifying bastion SSH login via port-forward with dedicated key..."
pf_log="$(mktemp)"
oc -n "${SSH_BASTION_NAMESPACE}" port-forward svc/ssh-bastion 12222:22 >"${pf_log}" 2>&1 &
pf_pid=$!
cleanup_pf() { kill "${pf_pid}" 2>/dev/null || true; }
trap 'cleanup_pf; rm -rf "${workdir}" "${bastion_key_dir}"' EXIT
for _ in $(seq 1 60); do
  if (echo >/dev/tcp/127.0.0.1/12222) >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
# Retry SSH a few times; first connection after port-forward can race briefly.
login_ok=false
for _ in $(seq 1 5); do
  if ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 -p 12222 -i "${SHARED_DIR}/medik8s_bastion_ssh_key" \
      core@127.0.0.1 'echo bastion-login-ok; hostname'; then
    login_ok=true
    break
  fi
  sleep 2
done
if [[ "${login_ok}" != "true" ]]; then
  echo "ERROR: bastion SSH login failed with dedicated key" >&2
  echo "--- port-forward log ---" >&2
  cat "${pf_log}" >&2 || true
  echo "--- bastion sshd logs ---" >&2
  oc -n "${SSH_BASTION_NAMESPACE}" logs "${bastion_pod}" --tail=80 >&2 || true
  dump_bastion_debug
  exit 1
fi
cleanup_pf
trap 'rm -rf "${workdir}" "${bastion_key_dir}"' EXIT
echo "Bastion SSH login verification succeeded"

echo "port-forward" > "${SHARED_DIR}/medik8s_ssh_bastion_mode"
echo "=== ssh-bastion ready ==="
