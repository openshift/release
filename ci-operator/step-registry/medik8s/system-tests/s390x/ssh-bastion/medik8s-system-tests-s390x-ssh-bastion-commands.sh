#!/bin/bash
# Gated ssh-bastion for medik8s system-tests on s390x libvirt OZ.
#
# The upstream eparis image (quay.io/eparis/ssh:latest) is amd64-only and will
# never schedule on s390x. This step deploys an equivalent sshd using a multi-
# arch centos stream9 image, authorized with the cluster SSH public key, then
# records port-forward mode for run-tests (libvirt has no cloud LB).

set -euo pipefail

if [[ "${MEDIK8S_S390X_SSH_BASTION:-false}" != "true" ]]; then
  echo "MEDIK8S_S390X_SSH_BASTION is not true; skipping ssh-bastion setup"
  exit 0
fi

echo "=== Deploying s390x-capable ssh-bastion for medik8s system-tests ==="

# Ensure our UID is in /etc/passwd (required for SSH from the step pod).
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
  # Needed so the bastion container can dnf-install openssh-server.
  # Also helps this step reach registries if the cluster uses an HTTP proxy.
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

echo "Generating ssh host keys and sshd_config..."
workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT
ssh-keygen -q -t rsa -f "${workdir}/ssh_host_rsa_key" -C '' -N ''
ssh-keygen -q -t ecdsa -f "${workdir}/ssh_host_ecdsa_key" -C '' -N ''
ssh-keygen -q -t ed25519 -f "${workdir}/ssh_host_ed25519_key" -C '' -N ''
cat > "${workdir}/sshd_config" <<'EOF'
HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ecdsa_key
HostKey /etc/ssh/ssh_host_ed25519_key
SyslogFacility AUTHPRIV
PermitRootLogin no
AuthorizedKeysFile /home/core/.ssh/authorized_keys
PasswordAuthentication no
ChallengeResponseAuthentication no
UsePAM no
X11Forwarding no
PrintMotd no
AllowTcpForwarding yes
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
  --from-file="authorized_keys=${SSH_PUB_KEY_FILE}"

echo "Creating ClusterIP Service (no cloud LB on libvirt)..."
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
    targetPort: ssh
  selector:
    run: ssh-bastion
  type: ClusterIP
EOF

# Multi-arch base (includes s390x). openssh-server is installed at container
# start so we do not depend on the amd64-only quay.io/eparis/ssh image.
echo "Creating ssh-bastion Deployment (quay.io/centos/centos:stream9)..."
oc -n "${SSH_BASTION_NAMESPACE}" apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    run: ssh-bastion
  name: ssh-bastion
spec:
  replicas: 1
  selector:
    matchLabels:
      run: ssh-bastion
  template:
    metadata:
      labels:
        run: ssh-bastion
    spec:
      serviceAccountName: ssh-bastion
      containers:
      - name: ssh-bastion
        image: quay.io/centos/centos:stream9
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 22
          name: ssh
          protocol: TCP
        securityContext:
          privileged: true
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
          dnf install -y openssh-server openssh-clients
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
          echo "Starting sshd..."
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
        oc -n "${SSH_BASTION_NAMESPACE}" logs "${pod}" --tail=80 >&2 || true
      done
}

echo "Waiting for ssh-bastion deployment to become Available..."
if ! oc -n "${SSH_BASTION_NAMESPACE}" rollout status deployment/ssh-bastion --timeout=5m; then
  dump_bastion_debug
  exit 1
fi
oc -n "${SSH_BASTION_NAMESPACE}" get pods,svc -o wide

# Libvirt has no LB; run-tests will oc port-forward this ClusterIP Service.
echo "No cloud LoadBalancer on libvirt OZ; run-tests will port-forward svc/ssh-bastion"
echo "port-forward" > "${SHARED_DIR}/medik8s_ssh_bastion_mode"

echo "=== ssh-bastion ready ==="
