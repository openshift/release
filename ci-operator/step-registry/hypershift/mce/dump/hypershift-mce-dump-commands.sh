#!/bin/bash

set -euo pipefail

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

HCP_CLI=""
echo "MCE version is greater than or equal to 2.4, need to extract HyperShift cli"
oc extract secret/pull-secret -n openshift-config --to=/tmp --confirm
HO_IMAGE=$(oc get deployment -n hypershift operator -ojsonpath='{.spec.template.spec.containers[*].image}')
mkdir /tmp/hs-cli
brew_registry_auth=$(echo -n "${BREW_IMAGE_REGISTRY_USERNAME}:$(<$BREW_IMAGE_REGISTRY_TOKEN_PATH)" | base64 -w 0)
echo '{}' | jq --arg auth "$brew_registry_auth" '.auths += {"brew.registry.redhat.io": {"auth": $auth}}' > /tmp/brew_configjson


NEW_HO_IMAGE=$(echo "$HO_IMAGE" | sed 's|registry.redhat.io/multicluster-engine|quay.io:443/acm-d|')
oc image extract "$NEW_HO_IMAGE" --path /usr/bin/hypershift-no-cgo:/tmp/hs-cli --registry-config=/tmp/.dockerconfigjson


chmod +x /tmp/hs-cli/hypershift-no-cgo
HCP_CLI="/tmp/hs-cli/hypershift-no-cgo"

CLUSTER_NAME="$(echo -n $PROW_JOB_ID|sha256sum|cut -c-20)"
HOSTED_CLUSTER_NS=$(oc get hostedcluster -A -ojsonpath='{.items[0].metadata.namespace}')
EXTRA_ARGS=""
PLATFORM_TYPE=$(oc get hostedclusters -n ${HOSTED_CLUSTER_NS} ${CLUSTER_NAME} -ojsonpath="{.spec.platform.type}")
if [[ "${PLATFORM_TYPE}" == "Agent" ]]; then
  EXTRA_ARGS="${EXTRA_ARGS} --agent-namespace local-cluster-${CLUSTER_NAME}"
fi

"${HCP_CLI}" dump cluster ${EXTRA_ARGS} \
--artifact-dir=$ARTIFACT_DIR \
--namespace ${HOSTED_CLUSTER_NS} \
--dump-guest-cluster=true \
--name="${CLUSTER_NAME}"

