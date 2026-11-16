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

echo "Enabling disable-udn-arp-ndp-flood feature (fix already in OVN-K binary post-merge)"

# Apply ConfigMap to activate the feature — no image override needed post-merge
oc apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ovn-kubernetes-config-overrides
  namespace: openshift-network-operator
data:
  disable-udn-arp-ndp-flood: "true"
EOF

echo "ConfigMap applied. Waiting for CNO to reconcile and trigger ovnkube-node rollout..."

# Wait for network-operator to restart (CNO picks up ConfigMap and restarts)
echo "Waiting for network-operator to process ConfigMap..."
for i in $(seq 1 30); do
  sleep 10
  # Check if ovnkube-node DaemonSet has an updated rollout (generation > 1 or observed changes)
  DESIRED=$(oc -n openshift-ovn-kubernetes get daemonset/ovnkube-node     -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
  UPDATED=$(oc -n openshift-ovn-kubernetes get daemonset/ovnkube-node     -o jsonpath='{.status.updatedNumberScheduled}' 2>/dev/null || echo "0")
  READY=$(oc -n openshift-ovn-kubernetes get daemonset/ovnkube-node     -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
  echo "Attempt ${i}/30: desired=${DESIRED} updated=${UPDATED} ready=${READY}"
  if [ "${DESIRED}" -gt 0 ] && [ "${UPDATED}" = "${DESIRED}" ] && [ "${READY}" = "${DESIRED}" ]; then
    # Check if the rollout includes our config (observed generation matches)
    OBS=$(oc -n openshift-ovn-kubernetes get daemonset/ovnkube-node       -o jsonpath='{.status.observedGeneration}' 2>/dev/null || echo "0")
    CUR=$(oc -n openshift-ovn-kubernetes get daemonset/ovnkube-node       -o jsonpath='{.metadata.generation}' 2>/dev/null || echo "0")
    [ "${OBS}" = "${CUR}" ] && echo "Rollout complete" && break
  fi
done

oc rollout status daemonset/ovnkube-node -n openshift-ovn-kubernetes --timeout=10m

echo "disable-udn-arp-ndp-flood enabled on all nodes"
