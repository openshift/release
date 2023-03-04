#!/bin/bash
set -x
set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

# create the openshift-storage namespace
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-storage
EOF

oc label namespace openshift-storage openshift.io/cluster-monitoring=true

# cd to writeable directory
cd tmp/

git clone https://github.com/stolostron/policy-collection.git

sleep 7200

# create 3 machinesets for ocp storage on aws
sed -i 's/inform/enforce/g' policy-collection/community/CM-Configuration-Management/policy-configure-subscription-admin-hub.yaml


# Need to enter pod to figure out how to get ami_id then I'll fix.
AMI_ID=$(oc get nodes)
export AMI_ID
sed -i 's/inform/enforce/g' policy-collection/community/CM-Configuration-Management/policy-aws-machine-sets.yaml

# wait for storage nodes to be ready
RETRIES=60
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

