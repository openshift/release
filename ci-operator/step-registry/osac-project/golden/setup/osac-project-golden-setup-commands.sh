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

echo "$(date +%T) Configuring cross-network forwarding..."
echo "--- Host firewall state before fix ---"
iptables -L FORWARD -n 2>&1 | head -5 || true
firewall-cmd --zone=libvirt --list-all 2>&1 || echo "no firewalld libvirt zone"
systemctl stop firewalld 2>/dev/null || true
systemctl disable firewalld 2>/dev/null || true
iptables -P FORWARD ACCEPT
iptables -I FORWARD -s 192.168.131.0/24 -d 192.168.130.0/24 -j ACCEPT
iptables -I FORWARD -s 192.168.130.0/24 -d 192.168.131.0/24 -j ACCEPT
echo "--- Host firewall state after fix ---"
iptables -L FORWARD -n 2>&1 | head -10 || true

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

echo "$(date +%T) Testing cross-VM connectivity (hub -> virt API)..."
echo "From host:"
curl -sk --connect-timeout 5 https://192.168.130.10:6443/readyz 2>&1 || echo "FAILED from host"
echo ""
echo "From hub VM:"
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 core@192.168.131.10 \
  "curl -sk --connect-timeout 5 https://192.168.130.10:6443/readyz 2>&1" || echo "CROSS-VM CONNECTIVITY FAILED"
echo ""

mkdir -p /root/.kube
cp "${GOLDEN_DIR}/hub/hub-kubeconfig" /root/.kube/config
cp "${GOLDEN_DIR}/virt/virt-kubeconfig" /root/virt-kubeconfig
echo 'export KUBECONFIG=/root/.kube/config' >> /root/.bashrc

HUB_KC="/root/.kube/config"
VIRT_KC="/root/virt-kubeconfig"

echo "$(date +%T) Waiting for ingress router..."
oc --kubeconfig="${HUB_KC}" rollout status deployment/router-default -n openshift-ingress --timeout=300s 2>&1 || true

echo "$(date +%T) Waiting for OSAC deployments to be available..."
for dep in $(oc --kubeconfig="${HUB_KC}" get deployments -n osac-e2e-ci -o name 2>/dev/null); do
  echo "$(date +%T) Waiting for ${dep}..."
  oc --kubeconfig="${HUB_KC}" rollout status "${dep}" -n osac-e2e-ci --timeout=300s 2>&1 || true
done

echo "$(date +%T) Waiting for cluster operators to stabilize..."
for i in $(seq 1 30); do
  progressing=$(oc --kubeconfig="${HUB_KC}" get co -o jsonpath='{range .items[*]}{.metadata.name}={.status.conditions[?(@.type=="Progressing")].status}{" "}{end}' 2>/dev/null \
    | tr ' ' '\n' | grep '=True' || true)
  if [[ -z "${progressing}" ]]; then
    echo "$(date +%T) All cluster operators stable (${i}0s)"
    break
  fi
  echo "$(date +%T) Still progressing: ${progressing}"
  sleep 10
done

echo "$(date +%T) Waiting for OSAC operator pod to stabilize..."
for i in $(seq 1 30); do
  restarts=$(oc --kubeconfig="${HUB_KC}" get pods -n osac-e2e-ci -l control-plane=controller-manager \
    -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo "-1")
  ready=$(oc --kubeconfig="${HUB_KC}" get pods -n osac-e2e-ci -l control-plane=controller-manager \
    -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || echo "false")
  if [[ "${ready}" == "true" ]]; then
    sleep 10
    new_restarts=$(oc --kubeconfig="${HUB_KC}" get pods -n osac-e2e-ci -l control-plane=controller-manager \
      -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo "-1")
    if [[ "${restarts}" == "${new_restarts}" ]]; then
      echo "$(date +%T) OSAC operator stable (ready, no restarts in 10s, total restarts: ${restarts})"
      break
    fi
    echo "$(date +%T) OSAC operator restarted (${restarts} -> ${new_restarts}), waiting..."
  else
    echo "$(date +%T) OSAC operator not ready yet (restarts: ${restarts})"
    sleep 10
  fi
done

echo "$(date +%T) Waiting for in-cluster DNS to resolve keycloak..."
for i in $(seq 1 30); do
  if oc --kubeconfig="${HUB_KC}" exec deployment/authorino -n osac-e2e-ci -- \
    sh -c 'nslookup keycloak.keycloak.svc.cluster.local 2>/dev/null | grep -q "Address"' 2>/dev/null; then
    echo "$(date +%T) In-cluster DNS ready (${i}0s)"
    break
  fi
  echo "$(date +%T) DNS not ready yet..."
  sleep 10
done

echo "$(date +%T) Waiting for Authorino AuthConfig to be ready..."
for i in $(seq 1 30); do
  ready=$(oc --kubeconfig="${HUB_KC}" get authconfig -n osac-e2e-ci \
    -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  if [[ "${ready}" == "True" ]]; then
    echo "$(date +%T) AuthConfig ready (${i}0s)"
    break
  fi
  if [[ $i -eq 6 ]]; then
    echo "$(date +%T) AuthConfig not ready after 60s, restarting Authorino..."
    oc --kubeconfig="${HUB_KC}" rollout restart deployment/authorino -n osac-e2e-ci 2>&1 || true
    oc --kubeconfig="${HUB_KC}" rollout status deployment/authorino -n osac-e2e-ci --timeout=120s 2>&1 || true
  fi
  echo "$(date +%T) AuthConfig not ready (status=${ready:-unknown})"
  sleep 10
done

echo "$(date +%T) Cluster health snapshot..."
echo "--- Hub deployments in osac-e2e-ci ---"
oc --kubeconfig="${HUB_KC}" get deployments -n osac-e2e-ci 2>&1 || true
echo "--- Hub pods in osac-e2e-ci ---"
oc --kubeconfig="${HUB_KC}" get pods -n osac-e2e-ci -o wide 2>&1 || true
echo "--- Hub cluster operators ---"
oc --kubeconfig="${HUB_KC}" get co 2>&1 || true
echo "--- Hub nodes ---"
oc --kubeconfig="${HUB_KC}" get nodes 2>&1 || true
echo "--- Virt nodes ---"
oc --kubeconfig="${VIRT_KC}" get nodes 2>&1 || true
echo "--- Virt KubeVirt status ---"
oc --kubeconfig="${VIRT_KC}" get kubevirt -A 2>&1 || true
echo "--- OSAC operator logs (last 50 lines) ---"
oc --kubeconfig="${HUB_KC}" logs deployment/osac-operator-controller-manager -n osac-e2e-ci --tail=50 2>&1 || true
echo "--- Fulfillment controller logs (last 30 lines) ---"
oc --kubeconfig="${HUB_KC}" logs deployment/fulfillment-controller -n osac-e2e-ci --tail=30 2>&1 || true

echo "$(date +%T) Golden image setup complete"
REMOTE_EOF

echo "$(date +%T) Copying virt kubeconfig to shared dir..."
scp -F "${SHARED_DIR}/ssh_config" ci_machine:/root/virt-kubeconfig "${SHARED_DIR}/virt-kubeconfig"

echo "$(date +%T) Golden setup complete"
