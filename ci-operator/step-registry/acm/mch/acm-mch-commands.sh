#!/bin/bash
set -x
set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig


# Apply MultiClusterHub custom resource definition
oc apply -f - <<EOF
apiVersion: "${API_VERSION}"
kind: MultiClusterHub
metadata:
  name: multiclusterhub
  namespace: "${NAMESPACE}"
spec: {}
EOF

# Need to sleep a bit before we start checking to see if MCH is running.
sleep 60

RETRIES=30
for i in $(seq "${RETRIES}"); do
  if [[ $(oc get mch -n ${NAMESPACE} -o=jsonpath='{.items[0].status.phase}') == "Running" ]]; then
    echo "MCH is Running"
    break
  else
    echo "Try ${i}/${RETRIES}: MCH is not running yet. Checking again in 30 seconds"
    sleep 30
  fi
done

echo "Successfully installed MCH"
