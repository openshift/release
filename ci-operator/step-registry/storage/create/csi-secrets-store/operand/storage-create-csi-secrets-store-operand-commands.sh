#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
	# shellcheck disable=SC1090
	source "${SHARED_DIR}/proxy-conf.sh"
fi

# set environment variables expected by Makefile
export REGISTRY=${SECRETS_STORE_CSI_DRIVER_IMAGE%/*}
PIPELINE=${SECRETS_STORE_CSI_DRIVER_IMAGE##*/}
export IMAGE_NAME=${PIPELINE%:*}
export IMAGE_VERSION=${SECRETS_STORE_CSI_DRIVER_IMAGE#*:}

# deploy the driver from manifests
echo "Deploying csi-secrets-store manifests"
make e2e-deploy-manifest CI=''

# wait for the daemonset pods to start
DAEMONSET_GET_ARGS="-n kube-system csi-secrets-store"
NUM_SCHEDULED=$(oc get daemonsets ${DAEMONSET_GET_ARGS} -o jsonpath='{.status.desiredNumberScheduled}')
echo "Waiting for ${NUM_SCHEDULED} csi-secrets-store daemonset pods to start"
if ! oc wait daemonsets ${DAEMONSET_GET_ARGS} --timeout=300s --for=jsonpath=.status.numberReady=${NUM_SCHEDULED}; then
	oc describe daemonset ${DAEMONSET_GET_ARGS}
	oc get daemonset ${DAEMONSET_GET_ARGS} -o yaml
	echo "Wait failed, E2E Provider pods did not reach Ready state"
	exit 1
fi
oc get pods -n kube-system
echo "csi-secrets-store daemonset pods started"
