#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ nutanix assisted test-infra post-install ************"
source ${SHARED_DIR}/platform-conf.sh
source ${SHARED_DIR}/nutanix_context.sh

export KUBECONFIG=${SHARED_DIR}/kubeconfig
oc project default

echo "Patching infrastructure/cluster"
oc patch infrastructure/cluster --type=merge --patch-file=/dev/stdin <<-EOF
{
  "spec": {
    "platformSpec": {
      "nutanix": {
        "prismCentral": {
          "address": "${NUTANIX_ENDPOINT}",
          "port": ${NUTANIX_PORT}
        },
        "prismElements": [
          {
            "endpoint": {
              "address": "${PE_HOST}",
              "port": ${PE_PORT}
            },
            "name": "${NUTANIX_CLUSTER_NAME}"
          }
        ]
      },
      "type": "Nutanix"
    }
  }
}
EOF
echo "infrastructure/cluster created"

cat <<EOF | oc create -f -
apiVersion: v1
kind: Secret
metadata:
   name: nutanix-credentials
   namespace: openshift-machine-api
type: Opaque
stringData:
  credentials: |
    [{"type":"basic_auth","data":{"prismCentral":{"username":"${NUTANIX_USERNAME}","password":"${NUTANIX_PASSWORD}"},"prismElements":null}}]
EOF
echo "machine API credentials created"

until \
  oc wait --all=true clusteroperator --for='condition=Available=True' >/dev/null && \
  oc wait --all=true clusteroperator --for='condition=Progressing=False' >/dev/null && \
  oc wait --all=true clusteroperator --for='condition=Degraded=False' >/dev/null;  do
    echo "$(date --rfc-3339=seconds) Clusteroperators not yet ready"
    sleep 1s
done
