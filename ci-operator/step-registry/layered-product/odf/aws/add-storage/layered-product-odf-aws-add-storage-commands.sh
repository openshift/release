#!/bin/bash
set -x
set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

# create the policies namespace
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-storage
EOF

oc label namespace openshift-storage openshift.io/cluster-monitoring=true

# create 3 machinesets for ocp storage on aws
CLUSTERID=$(oc get machineset -n openshift-machine-api -o jsonpath='{.items[0].metadata.labels.machine\.openshift\.io/cluster-api-cluster}')
echo $CLUSTERID

curl -s https://raw.githubusercontent.com/red-hat-storage/ocs-training/master/training/modules/ocs4/attachments/cluster-workerocs-us-east-2.yaml | sed -e "s/CLUSTERID/${CLUSTERID}/g" | oc apply -f -


# wait for storage nodes to be ready
RETRIES=30
for i in $(seq "${RETRIES}"); do
  if [[ $(oc get nodes -l cluster.ocs.openshift.io/openshift-storage= | grep Ready) ]]; then
    echo "storage worker nodes are up is Running"
    break
  else
    echo "Try ${i}/${RETRIES}: Storage nodes are not ready yet. Checking again in 30 seconds"
    sleep 30
  fi
done

echo "storage nodes are ready"

