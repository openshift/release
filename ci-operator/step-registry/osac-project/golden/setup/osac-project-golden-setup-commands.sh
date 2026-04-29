#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Setting up golden image environment"

echo "Merging pull secrets..."
jq -s '.[0] * .[1]' \
  "${CLUSTER_PROFILE_DIR}/pull-secret" \
  "/var/run/vault/brew-registry-redhat-io-pull-secret/pull-secret" \
  > /tmp/merged-pull-secret
scp -F "${SHARED_DIR}/ssh_config" /tmp/merged-pull-secret ci_machine:/root/pull-secret

timeout -s 9 35m ssh -F "${SHARED_DIR}/ssh_config" ci_machine bash -s \
  "${GOLDEN_HUB_IMAGE}" "${GOLDEN_VIRT_IMAGE}" <<'REMOTE_EOF'
set -euo pipefail

GOLDEN_HUB_IMAGE="$1"
GOLDEN_VIRT_IMAGE="$2"
GOLDEN_DIR="/data/golden"
PULL_SECRET="/root/pull-secret"

dnf install -y libvirt qemu-kvm podman dnsmasq
systemctl enable --now libvirtd

mkdir -p ~/.config/containers
cat > ~/.config/containers/containers.conf <<CONFEOF
[engine]
image_parallel_copies = 20
CONFEOF

mkdir -p "${GOLDEN_DIR}/hub" "${GOLDEN_DIR}/virt"

echo "Pulling golden images..."
podman pull --authfile "${PULL_SECRET}" "${GOLDEN_HUB_IMAGE}" &
podman pull --authfile "${PULL_SECRET}" "${GOLDEN_VIRT_IMAGE}" &
wait

echo "Extracting hub..."
podman create --name golden-hub "${GOLDEN_HUB_IMAGE}"
podman cp golden-hub:/ "${GOLDEN_DIR}/hub/"
podman rm golden-hub

echo "Extracting virt..."
podman create --name golden-virt "${GOLDEN_VIRT_IMAGE}"
podman cp golden-virt:/ "${GOLDEN_DIR}/virt/"
podman rm golden-virt

echo "Reassembling QCOW2s from chunks..."
cat "${GOLDEN_DIR}/hub/hub-os.chunk."* > "${GOLDEN_DIR}/hub/hub-os.qcow2"
rm -f "${GOLDEN_DIR}/hub/hub-os.chunk."*
cat "${GOLDEN_DIR}/hub/hub-data.chunk."* > "${GOLDEN_DIR}/hub/hub-data.qcow2"
rm -f "${GOLDEN_DIR}/hub/hub-data.chunk."*
cat "${GOLDEN_DIR}/virt/virt-os.chunk."* > "${GOLDEN_DIR}/virt/virt-os.qcow2"
rm -f "${GOLDEN_DIR}/virt/virt-os.chunk."*
cat "${GOLDEN_DIR}/virt/virt-data.chunk."* > "${GOLDEN_DIR}/virt/virt-data.qcow2"
rm -f "${GOLDEN_DIR}/virt/virt-data.chunk."*

echo "Creating networks..."
virsh net-define "${GOLDEN_DIR}/hub/hub-network.xml"
virsh net-start test-infra-net-d55276d8
virsh net-define "${GOLDEN_DIR}/virt/virt-network.xml"
virsh net-start test-infra-net-ad07fc71

echo "Fixing domain XMLs..."
python3 "${GOLDEN_DIR}/hub/fix-domain-xml.py" \
  "${GOLDEN_DIR}/hub/hub-domain.xml" \
  "${GOLDEN_DIR}/hub/hub-domain-fixed.xml" \
  "${GOLDEN_DIR}/hub/hub-os.qcow2" \
  "${GOLDEN_DIR}/hub/hub-data.qcow2" \
  "osac-extra-disk3" \
  "test-infra-net-d55276d8"

python3 "${GOLDEN_DIR}/virt/fix-domain-xml.py" \
  "${GOLDEN_DIR}/virt/virt-domain.xml" \
  "${GOLDEN_DIR}/virt/virt-domain-fixed.xml" \
  "${GOLDEN_DIR}/virt/virt-os.qcow2" \
  "${GOLDEN_DIR}/virt/virt-data.qcow2" \
  "disk2" \
  "test-infra-net-ad07fc71"

echo "Configuring DNS for cluster hostnames..."
cat > /etc/dnsmasq.d/golden-clusters.conf <<DNSEOF
address=/test-infra-cluster-d55276d8.redhat.com/192.168.131.10
address=/test-infra-cluster-ad07fc71.redhat.com/192.168.130.10
DNSEOF
systemctl enable --now dnsmasq
echo "nameserver 127.0.0.1" > /etc/resolv.conf.golden
cat /etc/resolv.conf >> /etc/resolv.conf.golden
cp /etc/resolv.conf.golden /etc/resolv.conf

echo "Starting VMs..."
virsh define "${GOLDEN_DIR}/hub/hub-domain-fixed.xml"
virsh start test-infra-cluster-d55276d8-master-0
virsh define "${GOLDEN_DIR}/virt/virt-domain-fixed.xml"
virsh start test-infra-cluster-ad07fc71-master-0

echo "Waiting for cluster APIs and ingress routers..."
for endpoint in "https://192.168.131.10:6443/readyz" "https://192.168.130.10:6443/readyz" "https://192.168.131.10:443/" "https://192.168.130.10:443/"; do
  ready=false
  for i in $(seq 1 60); do
    if curl -sk --connect-timeout 5 "${endpoint}" 2>/dev/null; then
      echo "${endpoint} reachable (${i}0s)"
      ready=true
      break
    fi
    sleep 10
  done
  if [[ "${ready}" != "true" ]]; then
    echo "ERROR: ${endpoint} did not become reachable within 600 seconds"
    exit 1
  fi
done

echo "Waiting for OSAC fulfillment service..."
ready=false
for i in $(seq 1 60); do
  if code=$(curl -sk --connect-timeout 5 -o /dev/null -w '%{http_code}' \
    https://fulfillment-api-osac-e2e-ci.apps.test-infra-cluster-d55276d8.redhat.com/); then
    if [[ "${code}" != "503" ]]; then
      echo "Fulfillment API ready (${i}0s, HTTP ${code})"
      ready=true
      break
    fi
  fi
  sleep 10
done
if [[ "${ready}" != "true" ]]; then
  echo "ERROR: Fulfillment API did not become ready within 600 seconds"
  exit 1
fi

mkdir -p /root/.kube
cp "${GOLDEN_DIR}/hub/hub-kubeconfig" /root/.kube/config
cp "${GOLDEN_DIR}/virt/virt-kubeconfig" /root/virt-kubeconfig
echo 'export KUBECONFIG=/root/.kube/config' >> /root/.bashrc

echo "Golden image setup complete"
REMOTE_EOF

echo "Copying virt kubeconfig to shared dir..."
scp -F "${SHARED_DIR}/ssh_config" ci_machine:/root/virt-kubeconfig "${SHARED_DIR}/virt-kubeconfig"

echo "Golden setup complete"
