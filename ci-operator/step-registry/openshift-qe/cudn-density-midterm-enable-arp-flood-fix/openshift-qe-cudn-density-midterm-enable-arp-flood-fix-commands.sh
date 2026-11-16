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

echo "ConfigMap applied. Waiting for CNO to process and ovnkube-node to roll out..."
sleep 30

oc rollout status daemonset/ovnkube-node -n openshift-ovn-kubernetes --timeout=10m

echo "disable-udn-arp-ndp-flood enabled on all nodes"
