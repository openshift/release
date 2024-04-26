#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds gather command ************"

if [[ ! -e "${SHARED_DIR}/server-ip" ]]; then
  echo "No server IP found; skipping log gathering."
  exit 0
fi

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

function getlogs() {
  echo "### Downloading logs..."
  scp "${SSHOPTS[@]}" "root@${IP}:/tmp/artifacts/*.tar*" "${ARTIFACT_DIR}"
}

# Gather logs regardless of what happens after this
trap getlogs EXIT

echo "### Gathering logs..."
timeout -s 9 15m ssh "${SSHOPTS[@]}" "root@${IP}" bash - <<EOF |& sed -e 's/.*auths.*/*** PULL_SECRET ***/g'
cd dev-scripts

echo "Get install-gather, if there is one..."
cp /root/dev-scripts/ocp/*/log-bundle*.tar.gz /tmp/artifacts/log-bundle-\$HOSTNAME.tar.gz || true

echo "Get sosreport including sar data..."
sos report --batch \
  -o container_log,filesys,kvm,libvirt,logs,networkmanager,podman,processor,rpm,sar,virsh \
  -k podman.all -k podman.logs \
  --tmp-dir /tmp/artifacts

echo "Get libvirt logs..."
tar -czC "/var/log/libvirt/qemu" -f "/tmp/artifacts/libvirt-logs.tar.gz" --transform "s?^\.?libvirt-logs?" .

. common.sh
. network.sh
. utils.sh

# Pass master and workers IPs to installer-gather script to collect info from nodes which didn't join the cluster
NODE_NAMES=()
for (( n=0; n<\$NUM_MASTERS; n++ ))
do
  NODE_NAMES+=(\$(printf \$MASTER_HOSTNAME_FORMAT \$n))
done
for (( n=0; n<\$NUM_WORKERS; n++ ))
do
  NODE_NAMES+=(\$(printf \$WORKER_HOSTNAME_FORMAT \$n))
done
for (( n=0; n<\$NUM_EXTRA_WORKERS; n++ ))
do
  NODE_NAMES+=("extraworker-%d")
done

NODE_IPS=()
for node_name in "${NODE_NAMES[@]}"
do
  node_ip=\$(sudo virsh net-dumpxml \$BAREMETAL_NETWORK_NAME | xmllint --xpath "string(//dns[*]/host/hostname[. = '\$node_name']/../@ip)" -)
    NODE_IPS+=("\$node_ip")
done

INTERNAL_SSH_OPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
)

# Collect sos report from each known node
for NODE_IP in \${NODE_IPS[@]}; do
  echo "Fetching SOS report from \${NODE_IP}"
  ssh "\${INTERNAL_SSH_OPTS[@]}" core@\${NODE_IP} sudo mkdir /run/artifacts &&
  ssh "\${INTERNAL_SSH_OPTS[@]}" core@\${NODE_IP} \
    sudo podman run -it --name toolbox --authfile /var/lib/kubelet/config.json --privileged --ipc=host --net=host --pid=host -e HOST=/host -e NAME=toolbox- -e IMAGE=registry.redhat.io/rhel8/support-tools:latest -v /run:/run -v /var/log:/var/log -v /etc/machine-id:/etc/machine-id -v /etc/localtime:/etc/localtime -v /:/host registry.redhat.io/rhel8/support-tools:latest \
        sos report --batch \
          -o container_log,filesys,logs,networkmanager,podman,processor,sar \
          -k podman.all -k podman.logs \
          --tmp-dir /run/artifacts && \
  ssh "\${INTERNAL_SSH_OPTS[@]}" core@\${NODE_IP} sudo chown -R core:core /run/artifacts
  scp "\${INTERNAL_SSH_OPTS[@]}" core@\${NODE_IP}:/run/artifacts/*.tar* /tmp/artifacts/ || true
done

echo "Get the bootstrap logs if it is around and we didn't already collect them..."
if ! compgen -G "/root/dev-scripts/ocp/ostest/log-bundle*.tar.gz" > /dev/null 2>&1
then
  # Collect log bundle
  ssh "${INTERNAL_SSH_OPTS[@]}" core@\$(wrap_if_ipv6 \$BOOTSTRAP_PROVISIONING_IP) TAR_FILE=/tmp/log-bundle-bootstrap.tar.gz sudo -E /usr/local/bin/installer-gather.sh --id bootstrap \${NODE_IPS[@]} &&
  scp "${INTERNAL_SSH_OPTS[@]}" core@\$(wrap_if_ipv6 \$BOOTSTRAP_PROVISIONING_IP):/tmp/log-bundle-bootstrap.tar.gz /tmp/artifacts/log-bundle-bootstrap.tar.gz || true
fi

echo "Get the proxy logs..."
if podman container exists external-squid
then
  mkdir -p /tmp/squid-logs-$NAMESPACE
  podman cp external-squid:/var/log/squid/access.log /tmp/squid-logs-$NAMESPACE || true
  podman cp external-squid:/var/log/squid/cache.log /tmp/squid-logs-$NAMESPACE || true
  tar -czC "/tmp" -f "/tmp/artifacts/squid-logs-$NAMESPACE.tar.gz" squid-logs-$NAMESPACE/
fi
EOF

echo "### Fetching must-gather image information..."
ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF |& sed -e 's/.*auths.*/*** PULL_SECRET ***/g'
cd /root/dev-scripts
source common.sh
source ocp_install_env.sh
source utils.sh
source network.sh

# In releases prior to 4.8, must-gather won't work on disconnected
# without specifying an image to use. This looks at the release payload,
# and generates the pullspec for the must-gather in our mirrored
# registry.
OPENSHIFT_VERSION=\$(openshift_version)
if printf '%s\n4.7\n' "\$OPENSHIFT_VERSION" | sort -V -C; then
  if [[ -n "\${MIRROR_IMAGES}" ]]; then
      MUST_GATHER_RELEASE_IMAGE=\$(image_for must-gather | cut -d '@' -f2)
      LOCAL_REGISTRY_PREFIX="\${LOCAL_REGISTRY_DNS_NAME}:\${LOCAL_REGISTRY_PORT}/localimages/local-release-image"
      echo "export MUST_GATHER_IMAGE=\"--image=\${LOCAL_REGISTRY_PREFIX}@\${MUST_GATHER_RELEASE_IMAGE}\"" >> /tmp/must-gather-image.sh
  fi
fi
EOF
scp "${SSHOPTS[@]}" "root@${IP}:/tmp/must-gather-image.sh" "${SHARED_DIR}/" || true
