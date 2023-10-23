#!/bin/bash
set -x
set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

# create image pull secret for MCH
oc create secret generic ${IMAGE_PULL_SECRET} -n ${MCH_NAMESPACE} --from-file=.dockerconfigjson=$CLUSTER_PROFILE_DIR/pull-secret --type=kubernetes.io/dockerconfigjson

echo "Apply multiclusterhub"
# apply MultiClusterHub crd
oc apply -f - <<EOF
apiVersion: operator.open-cluster-management.io/v1
kind: MultiClusterHub
metadata:
  name: multiclusterhub
  namespace: ${MCH_NAMESPACE}
spec:
  imagePullSecret: ${IMAGE_PULL_SECRET}
EOF

# Need to sleep a bit before start watching
sleep 60

RETRIES=30
for try in $(seq "${RETRIES}"); do
  if [[ $(oc get mch -n ${MCH_NAMESPACE} -o=jsonpath='{.items[0].status.phase}') == "Running" ]]; then
    acm_version=$(oc -n ${MCH_NAMESPACE} get mch multiclusterhub -o jsonpath='{.status.currentVersion}{"\n"}')
    echo "Success! ACM ${acm_version} is Running"
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
