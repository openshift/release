#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

test -f "${CLUSTER_PROFILE_DIR}/sp_id" || echo "sp_id is missing in cluster profile"
test -f "${CLUSTER_PROFILE_DIR}/sp_cert" || echo "sp_cert is missing in cluster profile"
test -f "${CLUSTER_PROFILE_DIR}/tenant_id" || echo "tenant_id is missing in cluster profile"

SP_ID="$(<"${CLUSTER_PROFILE_DIR}/sp_id")"
SP_CERT='${CLUSTER_PROFILE_DIR}/sp_cert'
TENANT_ID="$(<"${CLUSTER_PROFILE_DIR}/tenant_id")"

cat > "${SHARED_DIR}/azure-login.sh" << EOF
#!/bin/bash

az login --service-principal --username "$SP_ID" --password "$SP_CERT" --tenant "$TENANT_ID" --output none

EOF
