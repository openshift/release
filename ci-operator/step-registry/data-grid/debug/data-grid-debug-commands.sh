#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

oc apply -f - <<EOF
    apiVersion: v1
    kind: ConfigMap
    metadata:
        name: cluster-monitoring-config
        namespace: ds-integration
    data:
        config.yaml: |
            enableUserWorkload: true 
EOF


sleep 10800