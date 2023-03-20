#!/bin/bash
set -x
set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

echo "Apply multiclusterhub"
# apply MultiClusterHub crd
oc apply -f - <<EOF
apiVersion: operator.open-cluster-management.io/v1
kind: MultiClusterHub
metadata:
  name: multiclusterhub
  namespace: ${MCH_NAMESPACE}
spec: {}
EOF

# Need to sleep a bit before start watching
sleep 60

RETRIES=30
for try in $(seq "${RETRIES}"); do
  if [[ $(oc get mch -n ${MCH_NAMESPACE} -o=jsonpath='{.items[0].status.phase}') == "Running" ]]; then
    echo "Success MCH is Running"
    break
  else
    if [ $try == $RETRIES ]; then
      echo "Error MCH failed to reach Running status in alloted time."
      exit 1
    fi
    echo "Try ${try}/${RETRIES}: MCH is not running yet. Checking again in 30 seconds"
    sleep 30
  fi
done
