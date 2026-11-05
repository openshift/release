#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# shellcheck source=/dev/null
source "${SHARED_DIR}/env"
chmod 0600 "${SSH_PRIVATE_KEY_FILE}"

function gather() {
  ssh "${SSHOPTS[@]}" "${IP}" -- sudo journalctl --no-pager > "${ARTIFACT_DIR}/journal.log" || true
}
trap gather EXIT

timeout 5m bash -c "until ssh -q ${SSHOPTS[*]} ${IP} exit; do sleep 10; done"

# The upstream remote runner expects a host with a running container runtime; it
# takes care of the kubelet itself. The RHCOS boot image does not ship CRI-O (the
# MCO normally pivots to the OCP node image), so install the CRI-O static bundle
# the same way the upstream FCOS crio node e2e jobs do.
echo "Installing CRI-O ${CRIO_VERSION} on ${IP}"
timeout --kill-after 5m 30m ssh "${SSHOPTS[@]}" "${IP}" -- sudo CRIO_VERSION="${CRIO_VERSION}" bash -s <<'EOF'
set -xeuo pipefail
# Inputs: CRIO_VERSION (tag, full SHA, or release-X.Y / main to use the latest bundle of that branch).
cat /etc/os-release

# Mirrors kubernetes/test-infra jobs/e2e_node/crio/templates/base/root.yaml (FCOS).
# RHCOS differences: / is a read-only composefs (no /usr remount), so CRI-O's
# libexec goes to /usr/local/libexec on the writable /var/usrlocal.
LIBEXEC_CRIO_DIR=/usr/local/libexec/crio

# The runner puts its workspace (kubelet, e2e_node.test, cni) under /tmp.
mount -o remount,exec,suid /tmp

# Match the FCOS kernel default (RHEL defaults THP to "always"): with THP always the
# kubelet takes far fewer page faults than the Summary API test expects (>= 1000).
echo madvise > /sys/kernel/mm/transparent_hugepage/enabled

cat > /etc/sysctl.d/99-e2e-sysctl.conf <<'CONF'
# Increase kernel.pid_max and kernel.threads-max to maximum. This is needed for
# pid eviction tests, because systemd will set a system wide DefaultTasksMax
# based on mimunum of these values.
kernel.pid_max=4194304
kernel.threads-max=4194304
CONF
/usr/lib/systemd/systemd-sysctl

mkdir -p /etc/containers/registries.conf.d
cat > /etc/containers/registries.conf.d/99-localhost-insecure.conf <<'CONF'
# Required for e2e tests using the fake-registry-server which serves HTTP-only
[[registry]]
location = "localhost:5000"
insecure = true
CONF

mkdir -p /etc/crio/crio.conf.d
cat > /etc/crio/crio.conf.d/20-crio.conf <<CONF
[crio.image]
signature_policy = "/etc/crio/policy.json"

[crio.runtime]
log_level = "debug"
drop_infra_ctr = false
default_runtime = "crun"

[crio.runtime.runtimes.crun]
runtime_path = "${LIBEXEC_CRIO_DIR}/crun"
monitor_path = "${LIBEXEC_CRIO_DIR}/conmon"
# TODO: having the crun subcgroup breaks this collection remove this when that is fixed
default_annotations = { "run.oci.systemd.subgroup" = "" }

[crio.runtime.runtimes.runc]
runtime_path = "${LIBEXEC_CRIO_DIR}/runc"
monitor_path = "${LIBEXEC_CRIO_DIR}/conmon"

[crio.runtime.runtimes.test-handler]
runtime_path = "${LIBEXEC_CRIO_DIR}/runc"
monitor_path = "${LIBEXEC_CRIO_DIR}/conmon"
CONF

cat > /root/kubelet-e2e.te <<'TE'
module kubelet-e2e 1.0;

require {
        type iptables_t;
        type cgroup_t;
        type user_tmp_t;
        type init_t;
        type container_t;
        class dir { ioctl create open write };
        class file { append create lock map open read rename unlink write };
}

#============= init_t ==============
allow init_t user_tmp_t:file { append create lock map open read rename unlink write };

#============= container_t ==============
allow container_t user_tmp_t:dir { create open write };

#============= iptables_t ==============
allow iptables_t cgroup_t:dir ioctl;
TE
setenforce 1
checkmodule -M -m -o /root/kubelet-e2e.mod /root/kubelet-e2e.te
semodule_package -o /root/kubelet-e2e.pp -m /root/kubelet-e2e.mod
semodule -i /root/kubelet-e2e.pp
mkdir -p /var/lib/kubelet
chcon -R -u system_u -r object_r -t var_lib_t /var/lib/kubelet

# Install the CRI-O static bundle, same as the FCOS crio-install.service.
case "${CRIO_VERSION}" in
  main | release-*)
    CRIO_VERSION=$(curl --fail --retry 5 --retry-delay 3 -sSL "https://storage.googleapis.com/cri-o/latest-bundle-${CRIO_VERSION}.txt")
    ;;
esac
curl --fail --retry 5 --retry-delay 3 --silent --show-error https://raw.githubusercontent.com/cri-o/packaging/main/get |
  LIBEXEC_CRIO_DIR="${LIBEXEC_CRIO_DIR}" bash -s -- -t "${CRIO_VERSION}"
rm -f /etc/cni/net.d/87-podman-bridge.conflist
rm -f /etc/crio/crio.conf.d/10-crio.conf
mv /etc/cni/net.d/10-crio-bridge.conflist.disabled /etc/cni/net.d/10-crio-bridge.conflist
systemctl daemon-reload
systemctl enable --now crio.service

/usr/local/bin/crio version
/usr/local/bin/crictl --runtime-endpoint unix:///var/run/crio/crio.sock version
EOF

echo "Running node e2e against ${IP}"
export HOME=/tmp GOCACHE=/tmp/gocache
export ARTIFACTS="${ARTIFACT_DIR}"
# <node name>=<ssh address>: SSH goes to the public IP, but the node is named after
# the private IP so the in-VM apiserver can reach the kubelet (:10250 is not open
# on the public IP).
export REMOTE=true REMOTE_MODE=ssh HOSTS="${PRIVATE_IP}=${IP}"
export SSH_KEY="${SSH_PRIVATE_KEY_FILE}"
export SSH_OPTIONS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=90 -o LogLevel=ERROR"
export CONTAINER_RUNTIME_ENDPOINT=unix:///var/run/crio/crio.sock
export FOCUS="${NODE_E2E_FOCUS}" SKIP="${NODE_E2E_SKIP}" PARALLELISM="${NODE_E2E_PARALLELISM}"
export TIMEOUT="${NODE_E2E_TIMEOUT}" TEST_ARGS="${NODE_E2E_TEST_ARGS}"
make test-e2e-node
