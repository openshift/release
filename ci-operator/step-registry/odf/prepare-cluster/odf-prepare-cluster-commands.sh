#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

echo "Creating the ODF installation namespace"
oc apply -f - <<EOF
  apiVersion: v1
  kind: Namespace
  metadata:
      labels:
        openshift.io/cluster-monitoring: "true"
      name: "${ODF_INSTALL_NAMESPACE}"
EOF

echo "Selecting worker nodes for ODF"
oc label nodes cluster.ocs.openshift.io/openshift-storage='' --selector='node-role.kubernetes.io/worker' --overwrite
