#!/bin/bash
set -euo pipefail

function set_proxy () {
    if test -s "${SHARED_DIR}/proxy-conf.sh" ; then
        echo "setting the proxy"
        echo "source ${SHARED_DIR}/proxy-conf.sh"
        source "${SHARED_DIR}/proxy-conf.sh"
        export no_proxy=brew.registry.redhat.io,registry.stage.redhat.io,registry.redhat.io,registry.ci.openshift.org,quay.io,s3.us-east-1.amazonaws.com
        export NO_PROXY=brew.registry.redhat.io,registry.stage.redhat.io,registry.redhat.io,registry.ci.openshift.org,quay.io,s3.us-east-1.amazonaws.com
    else
        echo "no proxy setting."
    fi
}

set_proxy

echo "Creating openshift-local-storage namespace..."
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-local-storage
spec: {}
EOF

echo "Creating OperatorGroup for local-storage..."
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: local-storage
  namespace: openshift-local-storage
spec:
  targetNamespaces:
  - openshift-local-storage
  upgradeStrategy: Default
EOF

echo "Creating Subscription for local-storage-operator..."
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: local-storage-operator
  namespace: openshift-local-storage
spec:
  channel: stable
  installPlanApproval: Automatic
  name: local-storage-operator
  source: ${CATALOGSOURCE_NAME}
  sourceNamespace: openshift-marketplace
EOF

echo "Waiting for local-storage-operator CSV to be created..."
COUNTER=0
while [ $COUNTER -lt 300 ]; do
    CSV_NAME=$(oc get csv -n openshift-local-storage -l operators.coreos.com/local-storage-operator.openshift-local-storage -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -n "${CSV_NAME}" ]; then
        echo "CSV ${CSV_NAME} found"
        break
    fi
    sleep 5
    COUNTER=$((COUNTER + 5))
    echo "Waiting ${COUNTER}s for CSV to be created..."
done

if [ $COUNTER -ge 300 ]; then
    echo "ERROR: CSV was not created within timeout"
    oc get subscription -n openshift-local-storage
    oc get installplan -n openshift-local-storage
    exit 1
fi

echo "Waiting for local-storage-operator CSV to be in Succeeded phase..."
oc wait --for=jsonpath='{.status.phase}'=Succeeded \
  csv "${CSV_NAME}" \
  -n openshift-local-storage \
  --timeout=600s

echo "Local Storage Operator installed successfully!"
