#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

source "${SHARED_DIR}/nutanix_context.sh"

credobj="[{\"type\":\"basic_auth\",\"data\":{\"prismCentral\":{\"username\":\"${NUTANIX_USERNAME}\",\"password\":\"${NUTANIX_PASSWORD}\"},\"prismElements\":null}}]"
credentials=$( echo -n "${credobj}" | base64 -w 0 )

# machine-api credentials manifest
cat > "${SHARED_DIR}/manifest_openshift-machine-api-nutanix-credentials-credentials.yaml" << EOF
apiVersion: v1
kind: Secret
metadata:
   name: nutanix-credentials
   namespace: openshift-machine-api
type: Opaque
data:
  credentials: ${credentials}
EOF
