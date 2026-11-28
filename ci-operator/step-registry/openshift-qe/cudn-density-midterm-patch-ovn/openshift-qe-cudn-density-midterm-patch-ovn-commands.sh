#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  set +x
  source "${SHARED_DIR}/proxy-conf.sh"
  set -x
fi

echo "Applying OVN patch: OVN_IMAGE=${OVN_IMAGE} CNO_IMAGE=${CNO_IMAGE}"

# Step 1: Scale CVO to 0 to prevent it from reverting our changes
oc scale -n openshift-cluster-version deployment.apps/cluster-version-operator --replicas=0

# Step 2: Set patched OVN images on network-operator
oc -n openshift-network-operator set env deployment.apps/network-operator \
  OVN_IMAGE="${OVN_IMAGE}" \
  NETWORK_OPERATOR_IMAGE="${CNO_IMAGE}" \
  OVNKUBE_IMAGE="${OVN_IMAGE}"

oc -n openshift-network-operator set image deployment/network-operator \
  network-operator="${CNO_IMAGE}"

# Step 3: Apply disable-udn-arp-ndp-flood ConfigMap override
oc apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ovn-kubernetes-config-overrides
  namespace: openshift-network-operator
data:
  disable-udn-arp-ndp-flood: "true"
EOF

echo "OVN patch applied. Waiting for ovnkube-node rollout..."

# Step 4: Wait for network-operator to process the change
sleep 30

# Verify patch applied — wait for DaemonSet template to reflect OVN_IMAGE first
echo "Waiting for DaemonSet template to reference ${OVN_IMAGE}..."
for i in $(seq 1 20); do
  DS_IMAGE=$(oc -n openshift-ovn-kubernetes get daemonset/ovnkube-node     -o jsonpath='{.spec.template.spec.containers[?(@.name=="ovn-controller")].image}' 2>/dev/null || echo "")
  if [ "${DS_IMAGE}" = "${OVN_IMAGE}" ]; then
    echo "DaemonSet template updated to ${OVN_IMAGE}"
    break
  fi
  echo "Attempt ${i}/20: DaemonSet still has ${DS_IMAGE}, waiting..."
  sleep 15
done

oc rollout status daemonset/ovnkube-node -n openshift-ovn-kubernetes --timeout=20m

RUNNING_IMAGE=$(oc -n openshift-ovn-kubernetes get pods -l app=ovnkube-node   -o jsonpath='{.items[0].spec.containers[?(@.name=="ovn-controller")].image}' 2>/dev/null || echo "unknown")
echo "ovnkube-node image: ${RUNNING_IMAGE}"

if [ "${RUNNING_IMAGE}" != "${OVN_IMAGE}" ]; then
  echo "ERROR: Expected ${OVN_IMAGE} but got ${RUNNING_IMAGE}" >&2
  exit 1
fi
echo "OVN PATCH VERIFIED: ${OVN_IMAGE} running"
