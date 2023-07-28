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
