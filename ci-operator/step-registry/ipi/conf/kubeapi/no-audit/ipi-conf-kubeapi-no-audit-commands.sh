#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

cat >> "${SHARED_DIR}/manifest_kubeapi-no-audit.yml" << EOF
apiVersion: operator.openshift.io/v1
kind: KubeAPIServer
metadata:
  name: cluster
spec:
  unsupportedConfigOverrides:
    apiServerArguments:
      audit-log-path:
        - /dev/null
EOF
