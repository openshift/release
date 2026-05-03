#!/bin/bash

set -o nounset
set -o pipefail

echo "$(date +%T) Gathering OSAC diagnostics..."

GATHER_DIR="${ARTIFACT_DIR}/osac-gather"
mkdir -p "${GATHER_DIR}"

REDACT='s/eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/[TOKEN]/g'

ssh -F "${SHARED_DIR}/ssh_config" ci_machine bash <<'REMOTE_EOF' | sed -E "${REDACT}" > "${GATHER_DIR}/gather.log" 2>&1
set +e

KUBECONFIG="/root/.kube/config"
VIRT_KC="/root/virt-kubeconfig"
NS="osac-e2e-ci"

echo "========== HOST STATE =========="
echo "--- date ---"
date -u
echo "--- uptime ---"
uptime
echo "--- free ---"
free -h
echo "--- dmesg OOM ---"
dmesg 2>/dev/null | grep -i "oom\|killed process" | tail -20 || echo "none"
echo "--- resolv.conf ---"
cat /etc/resolv.conf
echo "--- dnsmasq ---"
systemctl is-active dnsmasq 2>&1
echo "--- VMs ---"
virsh list --all
for vm in $(virsh list --name 2>/dev/null); do
  echo "--- dommemstat ${vm} ---"
  virsh dommemstat "${vm}" 2>/dev/null || true
  echo "--- domblkstat ${vm} ---"
  virsh domblkstat "${vm}" 2>/dev/null || true
done
echo "--- Hub API ---"
curl -sk --connect-timeout 5 https://192.168.131.10:6443/readyz 2>&1 || echo "UNREACHABLE"
echo ""
echo "--- Virt API ---"
curl -sk --connect-timeout 5 https://192.168.130.10:6443/readyz 2>&1 || echo "UNREACHABLE"
echo ""

echo "========== HUB CLUSTER =========="
echo "--- nodes ---"
oc --kubeconfig="${KUBECONFIG}" get nodes -o wide 2>&1 || true
echo "--- cluster operators ---"
oc --kubeconfig="${KUBECONFIG}" get co 2>&1 || true
echo "--- pods in ${NS} ---"
oc --kubeconfig="${KUBECONFIG}" get pods -n "${NS}" -o wide 2>&1 || true
echo "--- deployments ---"
oc --kubeconfig="${KUBECONFIG}" get deployments -n "${NS}" 2>&1 || true
echo "--- events (last 100) ---"
oc --kubeconfig="${KUBECONFIG}" get events -n "${NS}" --sort-by=.lastTimestamp 2>&1 | tail -100 || true
echo "--- ComputeInstance ---"
oc --kubeconfig="${KUBECONFIG}" get computeinstance -n "${NS}" -o yaml 2>&1 || true
echo "--- VirtualNetwork ---"
oc --kubeconfig="${KUBECONFIG}" get virtualnetwork -n "${NS}" -o yaml 2>&1 || true
echo "--- Subnet ---"
oc --kubeconfig="${KUBECONFIG}" get subnet -n "${NS}" -o yaml 2>&1 || true
echo "--- AuthConfig ---"
oc --kubeconfig="${KUBECONFIG}" get authconfig -n "${NS}" -o yaml 2>&1 || true
echo "--- keycloak pods ---"
oc --kubeconfig="${KUBECONFIG}" get pods -n keycloak 2>&1 || true

echo "========== POD LOGS =========="
for dep in osac-operator-controller-manager fulfillment-controller fulfillment-grpc-server authorino osac-aap-gateway; do
  echo "---------- ${dep} ----------"
  oc --kubeconfig="${KUBECONFIG}" logs "deployment/${dep}" -n "${NS}" --tail=200 2>&1 || true
done
echo "---------- keycloak ----------"
oc --kubeconfig="${KUBECONFIG}" logs deployment/keycloak-service -n keycloak --tail=100 2>&1 || true

echo "========== KUBE-APISERVER =========="
echo "--- pods ---"
oc --kubeconfig="${KUBECONFIG}" get pods -n openshift-kube-apiserver -o wide 2>&1 || true
echo "--- CO ---"
oc --kubeconfig="${KUBECONFIG}" get co kube-apiserver -o yaml 2>&1 || true
echo "--- etcd pods ---"
oc --kubeconfig="${KUBECONFIG}" get pods -n openshift-etcd 2>&1 || true
echo "--- etcd CO ---"
oc --kubeconfig="${KUBECONFIG}" get co etcd -o yaml 2>&1 || true

echo "========== VIRT CLUSTER =========="
echo "--- nodes ---"
oc --kubeconfig="${VIRT_KC}" get nodes -o wide 2>&1 || true
echo "--- KubeVirt ---"
oc --kubeconfig="${VIRT_KC}" get kubevirt -A 2>&1 || true
echo "--- VMs ---"
oc --kubeconfig="${VIRT_KC}" get vm -A 2>&1 || true
echo "--- VMIs ---"
oc --kubeconfig="${VIRT_KC}" get vmi -A 2>&1 || true

echo "========== END OSAC GATHER =========="
REMOTE_EOF

echo "$(date +%T) OSAC gather complete"
