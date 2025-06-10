#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds single-node gather command ************"

if [[ ! -e "${SHARED_DIR}/server-ip" ]]; then
  echo "No server IP found; skipping log gathering."
  exit 0
fi

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

function getlogs() {
  echo "### Downloading logs..."
  scp -r "${SSHOPTS[@]}" "root@${IP}:/tmp/artifacts/*" "${ARTIFACT_DIR}"
}

# Gather logs regardless of what happens after this
trap getlogs EXIT

echo "### Gathering logs..."
timeout -s 9 20m ssh "${SSHOPTS[@]}" "root@${IP}" bash - << "EOF" |& sed -e 's/.*auths.*/*** PULL_SECRET ***/g'

set -xeo pipefail
source /root/config

# Get sosreport including sar data
sos report --batch --tmp-dir /tmp/artifacts --all-logs \
  -o memory,container_log,filesys,kvm,libvirt,logs,networkmanager,networking,podman,processor,rpm,sar,virsh,dnf \
  -k podman.all -k podman.logs

cp -v -r /var/log/swtpm/libvirt/qemu /tmp/artifacts/libvirt-qemu || true
ls -ltr /var/lib/swtpm-localca/ >> /tmp/artifacts/libvirt-qemu/ls-swtpm-localca.txt || true

INTERNAL_SSH_OPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
)
echo "Fetching SOS report from ${SINGLE_NODE_IP_ADDRESS}"
ssh "${INTERNAL_SSH_OPTS[@]}" core@${SINGLE_NODE_IP_ADDRESS} sudo mkdir /run/artifacts &&
ssh "${INTERNAL_SSH_OPTS[@]}" core@${SINGLE_NODE_IP_ADDRESS} \
  sudo podman run -it --name toolbox --authfile /var/lib/kubelet/config.json --privileged --ipc=host --net=host --pid=host -e HOST=/host -e NAME=toolbox- -e IMAGE=registry.redhat.io/rhel8/support-tools:latest -v /run:/run -v /var/log:/var/log -v /etc/machine-id:/etc/machine-id -v /etc/localtime:/etc/localtime -v /:/host registry.redhat.io/rhel8/support-tools:latest \
      sos report --case-id "\$HOSTNAME" --batch \
        -o container_log,filesys,logs,networkmanager,podman,processor,sar \
        -k podman.all -k podman.logs \
        --tmp-dir /run/artifacts && \
ssh "${INTERNAL_SSH_OPTS[@]}" core@${SINGLE_NODE_IP_ADDRESS} sudo chown -R core:core /run/artifacts &&
scp "${INTERNAL_SSH_OPTS[@]}" core@${SINGLE_NODE_IP_ADDRESS}:/run/artifacts/*.tar* /tmp/artifacts/ || true

echo "Copy content from setup step to artifacts dir..."
cp -r /home/sno/build/ /tmp/artifacts/

export KUBECONFIG=/home/sno/build/ibip/auth/kubeconfig

echo "Waiting for cluster API to be responsive..."
timeout 5m bash -c 'until oc version; do sleep 10; done' || true

must_gather_dir=/tmp/artifacts/post-tests-must-gather
mkdir -p "${must_gather_dir}"

# Download the MCO sanitizer binary from mirror
curl -sL "https://mirror.openshift.com/pub/ci/$(arch)/mco-sanitize/mco-sanitize" > /tmp/mco-sanitize
chmod +x /tmp/mco-sanitize

echo "Gathering must-gather data..."
oc adm must-gather \
  --insecure-skip-tls-verify \
  --dest-dir "${must_gather_dir}" > "${must_gather_dir}/must-gather.log"

# Sanitize MCO resources to remove sensitive information.
# If the sanitizer fails, fall back to manual redaction.
if ! /tmp/mco-sanitize --input="${must_gather_dir}"; then
  find "${must_gather_dir}" -type f -path '*/cluster-scoped-resources/machineconfiguration.openshift.io/*' -exec sh -c 'echo "REDACTED" > "\$1" && mv "\$1" "\$1.redacted"' _ {} \;
fi    

EOF
