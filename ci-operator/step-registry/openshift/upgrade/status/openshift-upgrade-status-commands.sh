#!/bin/bash
set -xeuo pipefail

function set_cluster_access() {
    if [ -f "${SHARED_DIR}/kubeconfig" ] ; then
        export KUBECONFIG=${SHARED_DIR}/kubeconfig
	echo "KUBECONFIG: ${KUBECONFIG}"
    fi
    cp -Lrvf "${KUBECONFIG}" /tmp/kubeconfig
    if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
        source "${SHARED_DIR}/proxy-conf.sh"
	echo "proxy: ${SHARED_DIR}/proxy-conf.sh"
    fi
}

set_cluster_access

echo "Displaying OpenShift upgrade status:"
OC_ENABLE_CMD_UPGRADE_STATUS=true oc adm upgrade status