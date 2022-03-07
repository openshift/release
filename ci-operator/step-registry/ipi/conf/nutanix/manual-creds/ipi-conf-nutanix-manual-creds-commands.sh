#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

source "${SHARED_DIR}/nutanix_context.sh"

NTNX_ENDPOINT=$( echo -n "${NUTANIX_HOST}" | base64 )
NTNX_PORT=$( echo -n "${NUTANIX_PORT}" | base64 )
NTNX_USER=$( echo -n "${NUTANIX_USERNAME}" | base64 )
NTNX_PASSWORD=$( echo -n "${NUTANIX_PASSWORD}" | base64 )

# machine-api credentials manifest
cat > "${SHARED_DIR}/manifest_openshift-machine-api-nutanix-credentials-credentials.yaml" << EOF
apiVersion: v1
kind: Secret
metadata:
   name: nutanix-credentials
   namespace: openshift-machine-api
type: Opaque
data:
  NUTANIX_ENDPOINT: ${NTNX_ENDPOINT}
  NUTANIX_PORT: ${NTNX_PORT}
  NUTANIX_USER: ${NTNX_USER}
  NUTANIX_PASSWORD: ${NTNX_PASSWORD}
EOF
