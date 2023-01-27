#!/bin/bash
set -x
set -o nounset
set -o errexit
set -o pipefail

echo "This is the acm-mch-command.sh space running"

export KUBECONFIG=${SHARED_DIR}/kubeconfig

echo "Apply multiclusterhub"
# apply MultiClusterHub crd
oc apply -f - <<EOF
apiVersion: operator.open-cluster-management.io/v1
kind: MultiClusterHub
metadata:
  name: multiclusterhub
  namespace: ocm
spec: {}
EOF

# can't wait before the resource exists. Need to sleep a bit before start watching
sleep 60

RETRIES=30
for i in $(seq "${RETRIES}"); do
  if [[ $(oc get mch -n ocm -o=jsonpath='{.items[0].status.phase}') == "Running" ]]; then
    echo "MCH is Running"
    break
  else
    echo "Try ${i}/${RETRIES}: MCH is not running yet. Checking again in 30 seconds"
    sleep 30
  fi
done

echo "successfully installed MCH"

sleep 600