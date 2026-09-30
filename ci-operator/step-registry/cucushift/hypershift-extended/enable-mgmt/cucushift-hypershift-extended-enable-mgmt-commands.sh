#!/bin/bash

set -euo pipefail

if [ -f "${SHARED_DIR}/cluster-type" ] ; then
    CLUSTER_TYPE=$(cat "${SHARED_DIR}/cluster-type")
    if [[ "$CLUSTER_TYPE" == "osd" ]] || [[ "$CLUSTER_TYPE" == "rosa" ]]; then
        cp "${SHARED_DIR}/kubeconfig" "${SHARED_DIR}/nested_kubeconfig"
        cat "${SHARED_DIR}/hs-mc.kubeconfig" > "${SHARED_DIR}/kubeconfig"
    else
      exit 1
    fi
fi
