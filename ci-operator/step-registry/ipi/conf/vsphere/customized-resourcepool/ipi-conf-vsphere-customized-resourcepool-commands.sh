#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "$(date -u --rfc-3339=seconds) - sourcing context from vsphere_context.sh..."
# shellcheck source=/dev/null
declare vsphere_cluster
source "${SHARED_DIR}/vsphere_context.sh"
# shellcheck source=/dev/null
source "${SHARED_DIR}/govc.sh"
unset SSL_CERT_FILE
unset GOVC_TLS_CA_CERTS


CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="${SHARED_DIR}/resourcepool.yaml.patch"

CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
rsp_name="${CLUSTER_NAME}-rsp"
govc pool.create ${vsphere_cluster}/Resources/${rsp_name}

cat > "${PATCH}" << EOF
platform:
  vsphere:
    failureDomains:
    - topology:
        resourcePool: ${vsphere_cluster}/Resources/${rsp_name}
EOF

yq-go m -x -i "${CONFIG}" "${PATCH}"
cat "${PATCH}"
