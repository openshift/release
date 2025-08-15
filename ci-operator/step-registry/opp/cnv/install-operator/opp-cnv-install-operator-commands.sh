#!/bin/bash
set -x
set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

# create the open-cluster-management namespace
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: open-cluster-management
EOF

# Label local-cluster with acm/cnv-operator-install: "true"
oc label managedcluster local-cluster acm/cnv-operator-install=true --overwrite

# Install CNV operator
cd /tmp/
git clone https://github.com/stolostron/mtv-integrations.git
cd mtv-integrations/addons/cnv-addon
oc apply -f ./

sleep 60

# Wait for cnv operator to be ready
RETRIES=40
for try in $(seq "${RETRIES}"); do
  if [[ $(oc get csv -n openshift-cnv -o name | grep "kubevirt-hyperconverged-operator") != "" ]]; then
    echo "CNV operator is installed successfully"
    break
  else
    if [ $try == $RETRIES ]; then
      echo "Error CNV operator is failed to install."
      exit 1
    fi
    echo "Try ${try}/${RETRIES}: CNV operator is not ready yet. Checking again in 30 seconds"
    sleep 30
  fi
done