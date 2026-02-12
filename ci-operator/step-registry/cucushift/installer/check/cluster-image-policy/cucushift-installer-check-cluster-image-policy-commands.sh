#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [ -f "${SHARED_DIR}/kubeconfig" ] ; then
    export KUBECONFIG=${SHARED_DIR}/kubeconfig
else
    echo "ERROR: fail to get the kubeconfig file under ${SHARED_DIR}!!"
    exit 1
fi

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

if [ -z "${OPENSHIFT_INSTALL_EXPERIMENTAL_DISABLE_IMAGE_POLICY:-}" ]; then
    echo "Skipping check: OPENSHIFT_INSTALL_EXPERIMENTAL_DISABLE_IMAGE_POLICY is not set."
    exit 0
fi

if [[ "$(oc get clusterversion.config.openshift.io version -o jsonpath='{.spec.overrides[?(@.kind=="ClusterImagePolicy")].unmanaged}')" == *true* ]]; then
    echo "ClusterImagePolicy is correctly set to 'unmanaged: true' in the ClusterVersion overrides."
    exit 0
else
    echo "The required 'unmanaged: true' override for ClusterImagePolicy was not found."
    exit 1
fi
