#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "$(date +%T) Setting up golden image environment"

echo "$(date +%T) Merging pull secrets..."
jq -s '.[0] * .[1]' \
  "${CLUSTER_PROFILE_DIR}/pull-secret" \
  "/var/run/vault/brew-registry-redhat-io-pull-secret/pull-secret" \
  > /tmp/merged-pull-secret
scp -F "${SHARED_DIR}/ssh_config" /tmp/merged-pull-secret ci_machine:/root/pull-secret

timeout -s 9 50m ssh -F "${SHARED_DIR}/ssh_config" ci_machine bash -s \
  "${GOLDEN_HUB_IMAGE}" "${GOLDEN_VIRT_IMAGE}" <<'REMOTE_EOF'
set -euo pipefail

GOLDEN_HUB_IMAGE="$1"
GOLDEN_VIRT_IMAGE="$2"
GOLDEN_DIR="/data/golden"
PULL_SECRET="/root/pull-secret"

echo "$(date +%T) Installing packages..."
dnf install -y libvirt qemu-kvm podman dnsmasq
systemctl enable --now libvirtd

echo "$(date +%T) Installing oc client..."
curl -sL https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz \
  | tar xzf - -C /usr/local/bin oc kubectl

mkdir -p ~/.config/containers
cat > ~/.config/containers/containers.conf <<CONFEOF
[engine]
image_parallel_copies = 20
CONFEOF

mkdir -p "${GOLDEN_DIR}/hub" "${GOLDEN_DIR}/virt"

echo "$(date +%T) Pulling golden images..."
podman pull --authfile "${PULL_SECRET}" "${GOLDEN_HUB_IMAGE}" &
podman pull --authfile "${PULL_SECRET}" "${GOLDEN_VIRT_IMAGE}" &
wait
echo "$(date +%T) Pull complete"

echo "$(date +%T) Extracting hub..."
podman create --name golden-hub "${GOLDEN_HUB_IMAGE}"
podman cp golden-hub:/ "${GOLDEN_DIR}/hub/"
podman rm golden-hub

echo "$(date +%T) Extracting virt..."
podman create --name golden-virt "${GOLDEN_VIRT_IMAGE}"
podman cp golden-virt:/ "${GOLDEN_DIR}/virt/"
podman rm golden-virt
echo "$(date +%T) Extraction complete"

echo "$(date +%T) Reassembling QCOW2s from chunks..."
cat "${GOLDEN_DIR}/hub/hub-os.chunk."* > "${GOLDEN_DIR}/hub/hub-os.qcow2"
rm -f "${GOLDEN_DIR}/hub/hub-os.chunk."*
cat "${GOLDEN_DIR}/hub/hub-data.chunk."* > "${GOLDEN_DIR}/hub/hub-data.qcow2"
rm -f "${GOLDEN_DIR}/hub/hub-data.chunk."*
cat "${GOLDEN_DIR}/virt/virt-os.chunk."* > "${GOLDEN_DIR}/virt/virt-os.qcow2"
rm -f "${GOLDEN_DIR}/virt/virt-os.chunk."*
cat "${GOLDEN_DIR}/virt/virt-data.chunk."* > "${GOLDEN_DIR}/virt/virt-data.qcow2"
rm -f "${GOLDEN_DIR}/virt/virt-data.chunk."*
echo "$(date +%T) Reassembly complete"

echo "$(date +%T) Creating networks..."
virsh net-define "${GOLDEN_DIR}/hub/hub-network.xml"
virsh net-start test-infra-net-d55276d8
virsh net-define "${GOLDEN_DIR}/virt/virt-network.xml"
virsh net-start test-infra-net-ad07fc71

echo "$(date +%T) Fixing domain XMLs..."
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

echo "$(date +%T) Configuring DNS for cluster hostnames..."
cat > /etc/dnsmasq.d/golden-clusters.conf <<DNSEOF
address=/test-infra-cluster-d55276d8.redhat.com/192.168.131.10
address=/test-infra-cluster-ad07fc71.redhat.com/192.168.130.10
DNSEOF
systemctl enable --now dnsmasq
echo "nameserver 127.0.0.1" > /etc/resolv.conf.golden
cat /etc/resolv.conf >> /etc/resolv.conf.golden
cp /etc/resolv.conf.golden /etc/resolv.conf

echo "$(date +%T) Starting VMs..."
virsh define "${GOLDEN_DIR}/hub/hub-domain-fixed.xml"
virsh start test-infra-cluster-d55276d8-master-0
virsh define "${GOLDEN_DIR}/virt/virt-domain-fixed.xml"
virsh start test-infra-cluster-ad07fc71-master-0

echo "$(date +%T) Waiting for all endpoints (parallel)..."

wait_for_endpoint() {
  local endpoint="$1"
  local label="$2"
  for i in $(seq 1 60); do
    if curl -sk --connect-timeout 5 "${endpoint}" 2>/dev/null; then
      echo "$(date +%T) ${label} reachable (${i}0s)"
      return 0
    fi
    sleep 10
  done
  echo "$(date +%T) ERROR: ${label} did not become reachable within 600s"
  return 1
}

wait_for_fulfillment() {
  for i in $(seq 1 60); do
    if code=$(curl -sk --connect-timeout 5 -o /dev/null -w '%{http_code}' \
      https://fulfillment-api-osac-e2e-ci.apps.test-infra-cluster-d55276d8.redhat.com/); then
      if [[ "${code}" != "503" ]]; then
        echo "$(date +%T) Fulfillment API ready (${i}0s, HTTP ${code})"
        return 0
      fi
    fi
    sleep 10
  done
  echo "$(date +%T) ERROR: Fulfillment API did not become ready within 600s"
  return 1
}

wait_for_endpoint "https://192.168.131.10:6443/readyz" "Hub API (6443)" &
wait_for_endpoint "https://192.168.130.10:6443/readyz" "Virt API (6443)" &
wait_for_endpoint "https://192.168.131.10:443/" "Hub ingress (443)" &
wait_for_endpoint "https://192.168.130.10:443/" "Virt ingress (443)" &
wait_for_fulfillment &

failed=0
for pid in $(jobs -p); do
  wait "${pid}" || failed=1
done
if [[ "${failed}" -ne 0 ]]; then
  echo "$(date +%T) ERROR: One or more endpoints failed readiness checks"
  exit 1
fi

echo "$(date +%T) All endpoints ready"

mkdir -p /root/.kube
cp "${GOLDEN_DIR}/hub/hub-kubeconfig" /root/.kube/config
cp "${GOLDEN_DIR}/virt/virt-kubeconfig" /root/virt-kubeconfig
echo 'export KUBECONFIG=/root/.kube/config' >> /root/.bashrc

echo "$(date +%T) Checking cluster health..."
echo "--- Hub cluster pods in osac-e2e-ci namespace ---"
oc --kubeconfig=/root/.kube/config get pods -n osac-e2e-ci -o wide 2>&1 || true
echo "--- Hub cluster deployments in osac-e2e-ci namespace ---"
oc --kubeconfig=/root/.kube/config get deployments -n osac-e2e-ci 2>&1 || true
echo "--- Hub cluster nodes ---"
oc --kubeconfig=/root/.kube/config get nodes 2>&1 || true
echo "--- Hub cluster clusteroperators (degraded) ---"
oc --kubeconfig=/root/.kube/config get co 2>&1 | grep -E 'NAME|False|True.*True' || true
echo "--- Virt cluster nodes ---"
oc --kubeconfig=/root/virt-kubeconfig get nodes 2>&1 || true
echo "--- Virt cluster KubeVirt status ---"
oc --kubeconfig=/root/virt-kubeconfig get kubevirt -A 2>&1 || true
echo "--- Virt cluster pods not ready in openshift-cnv ---"
oc --kubeconfig=/root/virt-kubeconfig get pods -n openshift-cnv --field-selector=status.phase!=Running 2>&1 || true

echo "$(date +%T) Waiting for OSAC deployments to be available..."
for dep in $(oc --kubeconfig=/root/.kube/config get deployments -n osac-e2e-ci -o name 2>/dev/null); do
  echo "$(date +%T) Waiting for ${dep}..."
  oc --kubeconfig=/root/.kube/config rollout status "${dep}" -n osac-e2e-ci --timeout=300s 2>&1 || true
done

echo "$(date +%T) Golden image setup complete"
REMOTE_EOF

echo "$(date +%T) Copying virt kubeconfig to shared dir..."
scp -F "${SHARED_DIR}/ssh_config" ci_machine:/root/virt-kubeconfig "${SHARED_DIR}/virt-kubeconfig"

echo "$(date +%T) Golden setup complete"
