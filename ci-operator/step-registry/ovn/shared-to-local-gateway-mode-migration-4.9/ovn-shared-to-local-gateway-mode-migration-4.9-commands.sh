#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

echo "Changing to local gateway mode"
echo "-------------------"

cat >> "${SHARED_DIR}/gateway-mode.yaml" << EOF
apiVersion: v1
kind: ConfigMap
metadata:
    name: gateway-mode-config
    namespace: openshift-network-operator
data:
    mode: "local"
immutable: true
EOF
echo "gateway-mode.yaml"
echo "---------------------------------------------"
cat ${SHARED_DIR}/gateway-mode.yaml

oc create -f ${SHARED_DIR}/gateway-mode.yaml
echo "gateway-mode-config-map"
echo "---------------------------------------------"
oc get -n openshift-network-operator cm gateway-mode-config -oyaml

# Giving upto 5mins for CNO to pick this up because each reconciliation loop is 5mins apart
oc wait co network --for='condition=PROGRESSING=True' --timeout=300s
# Wait until the ovn-kubernetes pods are restarted
timeout 600s oc rollout status ds/ovnkube-node -n openshift-ovn-kubernetes
timeout 600s oc rollout status ds/ovnkube-master -n openshift-ovn-kubernetes

# ensure the gateway mode change was successful, if not no use proceeding with the test
mode=$(oc get -n openshift-network-operator cm gateway-mode-config -o template --template '{{.data.mode}}')
echo "OVN gateway mode is set to ${mode}"
if [[ "${mode}" = "local" ]]; then
  echo "Overriding to OVN local gateway mode was a success"
else
  echo "Overriding to OVN local gateway mode was a faiure"
  exit 1
fi
