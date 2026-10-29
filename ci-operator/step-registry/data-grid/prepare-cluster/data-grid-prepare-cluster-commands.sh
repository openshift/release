#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Creating the dg-integration namespace..."

oc apply -f - <<EOF
    apiVersion: v1
    kind: Namespace
    metadata:
        name: "dg-integration"
EOF

echo "Creating the xtf-builds namespace..."

oc apply -f - <<EOF
    apiVersion: v1
    kind: Namespace
    metadata:
        name: "xtf-builds"
EOF

echo "Enabling monitoring..."

oc apply -f - <<EOF
    apiVersion: v1
    kind: ConfigMap
    metadata:
        name: cluster-monitoring-config
        namespace: openshift-monitoring
    data:
        config.yaml: |
            enableUserWorkload: true 
EOF

oc -n openshift-user-workload-monitoring adm policy add-role-to-user user-workload-monitoring-config-edit system:admin --role-namespace openshift-user-workload-monitoring
