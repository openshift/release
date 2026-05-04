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
  "${AGENT_VM_VCPUS}" "${AGENT_VM_DISK_SIZE}" <<'REMOTE_EOF'
set -euo pipefail

AGENT_NAMESPACE="$1"
AGENT_RESOURCE_CLASS="$2"
AGENT_VM_MEMORY="$3"
AGENT_VM_VCPUS="$4"
AGENT_VM_DISK_SIZE="$5"

KUBECONFIG=$(find ${KUBECONFIG} -type f -print -quit)

SNO_VM=$(virsh list --name | grep -m1 .)
LIBVIRT_NET=$(virsh domiflist "${SNO_VM}" | awk '/network/{print $3}')
SNO_IP=$(virsh net-dhcp-leases "${LIBVIRT_NET}" | awk 'NR>2 && $5{gsub(/\/.*/, "", $5); print $5; exit}')
CLUSTER_DOMAIN=$(oc get dnses.config.openshift.io cluster -o jsonpath='{.spec.baseDomain}')

oc patch secret cluster-fulfillment-ig -n osac-system --type merge \
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
  --boot hd,cdrom

virsh start ci-agent

echo "Waiting for agent to register..."
AGENT_NAME=""
for i in $(seq 1 120); do
  AGENT_NAME=$(oc get agents -n "${AGENT_NAMESPACE}" -o name 2>/dev/null | head -1 || true)
  [[ -n "${AGENT_NAME}" ]] && break
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
