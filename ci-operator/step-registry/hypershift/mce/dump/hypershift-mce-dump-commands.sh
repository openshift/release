#!/bin/bash

set -xeuo pipefail

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

HCP_CLI=""
echo "MCE version is greater than or equal to 2.4, need to extract HyperShift cli"
mkdir /tmp/hs-cli
HCP_CLI="/tmp/hs-cli/hypershift"
# >= 2.9
if [[ "$(printf '%s\n' "2.9" "$MCE_VERSION" | sort -V | head -n1)" == "2.9" ]]; then
  oc cp -n hypershift "$(oc get pod -n hypershift -l app=operator -o jsonpath='{.items[0].metadata.name}')":/usr/bin/hypershift /tmp/hs-cli/hypershift
else
  set +x
  oc extract secret/pull-secret -n openshift-config --to=/tmp --confirm
  HO_IMAGE=$(oc get deployment -n hypershift operator -ojsonpath='{.spec.template.spec.containers[*].image}')
  brew_registry_auth=$(echo -n "${BREW_IMAGE_REGISTRY_USERNAME}:$(<$BREW_IMAGE_REGISTRY_TOKEN_PATH)" | base64 -w 0)
  echo '{}' | jq --arg auth "$brew_registry_auth" '.auths += {"brew.registry.redhat.io": {"auth": $auth}}' > /tmp/brew_configjson
  oc image extract "brew.${HO_IMAGE}" --path /usr/bin/hypershift-no-cgo:/tmp/hs-cli --registry-config=/tmp/brew_configjson
  HCP_CLI="/tmp/hs-cli/hypershift-no-cgo"
  set -x
fi
chmod +x "$HCP_CLI"

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

