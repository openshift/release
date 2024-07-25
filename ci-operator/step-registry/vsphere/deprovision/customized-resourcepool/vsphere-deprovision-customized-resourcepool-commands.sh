#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

echo "$(date -u --rfc-3339=seconds) - sourcing context from vsphere_context.sh..."
# shellcheck source=/dev/null
declare vsphere_datacenter
declare vsphere_cluster
source "${SHARED_DIR}/vsphere_context.sh"
# shellcheck source=/dev/null
source "${SHARED_DIR}/govc.sh"
unset SSL_CERT_FILE
unset GOVC_TLS_CA_CERTS

CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
rsp_name="${CLUSTER_NAME}-rsp"

if [[ -n "$(govc ls /${vsphere_datacenter}/host/${vsphere_cluster}/Resources/${rsp_name})" ]];then
    echo "customized resource pool found, will delete."
else
    echo "cusomized resource pool not found.skip deprovision"
    exit 0
fi

govc pool.destroy /${vsphere_datacenter}/host/${vsphere_cluster}/Resources/${rsp_name}
