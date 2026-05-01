#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ osac-project-caas-agent-setup ************"
echo "--- Running with the following parameters ---"
echo "AGENT_NAMESPACE: ${AGENT_NAMESPACE}"
echo "AGENT_RESOURCE_CLASS: ${AGENT_RESOURCE_CLASS}"
echo "AGENT_VM_MEMORY: ${AGENT_VM_MEMORY}"
echo "AGENT_VM_VCPUS: ${AGENT_VM_VCPUS}"
echo "AGENT_VM_DISK_SIZE: ${AGENT_VM_DISK_SIZE}"
echo "-------------------------------------------"

timeout -s 9 25m ssh -F "${SHARED_DIR}/ssh_config" ci_machine bash -s \
  "${AGENT_NAMESPACE}" "${AGENT_RESOURCE_CLASS}" "${AGENT_VM_MEMORY}" \
  "${AGENT_VM_VCPUS}" "${AGENT_VM_DISK_SIZE}" "${E2E_NAMESPACE}" <<'REMOTE_EOF'
set -euo pipefail

AGENT_NAMESPACE="$1"
AGENT_RESOURCE_CLASS="$2"
AGENT_VM_MEMORY="$3"
AGENT_VM_VCPUS="$4"
AGENT_VM_DISK_SIZE="$5"
E2E_NAMESPACE="$6"

KUBECONFIG=$(find ${KUBECONFIG} -type f -print -quit)

SNO_VM=$(virsh list --name | grep -m1 .)
LIBVIRT_NET=$(virsh domiflist "${SNO_VM}" | awk '/network/{print $3; exit}')
SNO_IP=$(virsh net-dhcp-leases "${LIBVIRT_NET}" | awk 'NR>2 && $5{gsub(/\/.*/, "", $5); print $5; exit}')
CLUSTER_DOMAIN=$(oc get dnses.config.openshift.io cluster -o jsonpath='{.spec.baseDomain}')
APPS_DOMAIN="apps.${CLUSTER_DOMAIN}"

echo "SNO IP: ${SNO_IP}, Apps domain: ${APPS_DOMAIN}"

# Add DNS entries so the libvirt dnsmasq resolves cluster routes for the agent VM
virsh net-update "${LIBVIRT_NET}" add dns-host \
  "<host ip='${SNO_IP}'><hostname>assisted-image-service-multicluster-engine.${APPS_DOMAIN}</hostname><hostname>assisted-service-multicluster-engine.${APPS_DOMAIN}</hostname><hostname>api.${CLUSTER_DOMAIN}</hostname></host>" \
  --live --config 2>&1 || true

echo "Libvirt network DNS config:"
virsh net-dumpxml "${LIBVIRT_NET}" | grep -A2 "<dns>" || true

oc patch secret cluster-fulfillment-ig -n "${E2E_NAMESPACE}" --type merge \
  -p "{\"stringData\":{\"HOSTED_CLUSTER_BASE_DOMAIN\":\"${CLUSTER_DOMAIN}\"}}"

oc create namespace "${AGENT_NAMESPACE}" --dry-run=client -o yaml | oc apply -f -

oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' \
  | base64 -d > /tmp/agent-pull-secret.json
oc create secret generic pull-secret -n "${AGENT_NAMESPACE}" \
  --from-file=.dockerconfigjson=/tmp/agent-pull-secret.json \
  --type=kubernetes.io/dockerconfigjson --dry-run=client -o yaml | oc apply -f -

cat <<INFRAEOF | oc apply -f -
apiVersion: agent-install.openshift.io/v1beta1
kind: InfraEnv
metadata:
  name: ci-agent-infraenv
  namespace: ${AGENT_NAMESPACE}
spec:
  pullSecretRef:
    name: pull-secret
INFRAEOF

echo "Waiting for ISO download URL..."
ISO_URL=""
for i in $(seq 1 60); do
  ISO_URL=$(oc get infraenv ci-agent-infraenv -n "${AGENT_NAMESPACE}" \
    -o jsonpath='{.status.isoDownloadURL}' 2>/dev/null || true)
  [[ -n "${ISO_URL}" ]] && break
  sleep 5
done
[[ -z "${ISO_URL}" ]] && echo "ERROR: ISO URL not available" && exit 1
echo "ISO URL: ${ISO_URL}"

curl -k -L -o /tmp/agent.iso "${ISO_URL}"

CONSOLE_LOG=/tmp/ci-agent-console.log
virt-install \
  --name ci-agent \
  --memory "${AGENT_VM_MEMORY}" \
  --vcpus "${AGENT_VM_VCPUS}" \
  --disk size="${AGENT_VM_DISK_SIZE%%G*}",format=qcow2 \
  --cdrom /tmp/agent.iso \
  --network network="${LIBVIRT_NET}" \
  --os-variant rhel9-unknown \
  --noautoconsole \
  --noreboot \
  --boot cdrom,hd \
  --serial file,path="${CONSOLE_LOG}"

echo "--- VM diagnostics (after 60s boot) ---"
sleep 60
virsh domstate ci-agent
echo "DHCP leases on ${LIBVIRT_NET}:"
virsh net-dhcp-leases "${LIBVIRT_NET}"
echo "InfraEnv status:"
oc get infraenv ci-agent-infraenv -n "${AGENT_NAMESPACE}" -o jsonpath='{.status.conditions[*].message}' 2>/dev/null || true
echo ""
echo "--- VM console output (last 50 lines) ---"
tail -50 "${CONSOLE_LOG}" 2>/dev/null || echo "(no console output)"
echo "--- end diagnostics ---"

echo "Waiting for agent to register..."
AGENT_NAME=""
for i in $(seq 1 120); do
  AGENT_NAME=$(oc get agents -n "${AGENT_NAMESPACE}" -o name 2>/dev/null | head -1 || true)
  [[ -n "${AGENT_NAME}" ]] && break
  if (( i % 12 == 0 )); then
    echo "Still waiting... ($(( i * 10 ))s elapsed)"
    virsh domstate ci-agent
    tail -5 "${CONSOLE_LOG}" 2>/dev/null || true
  fi
  sleep 10
done
[[ -z "${AGENT_NAME}" ]] && echo "ERROR: Agent did not register" && exit 1
echo "Agent registered: ${AGENT_NAME}"

oc label "${AGENT_NAME}" -n "${AGENT_NAMESPACE}" \
  "resource_class=${AGENT_RESOURCE_CLASS}" --overwrite

oc patch "${AGENT_NAME}" -n "${AGENT_NAMESPACE}" --type merge \
  -p '{"spec":{"approved":true}}'

echo "Agent setup complete"
REMOTE_EOF
