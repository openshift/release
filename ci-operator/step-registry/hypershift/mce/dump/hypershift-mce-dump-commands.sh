#!/bin/bash

set -euo pipefail

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

MCE_VERSION=$(oc get "$(oc get multiclusterengines -oname)" -ojsonpath="{.status.currentVersion}" | cut -c 1-3)
HCP_CLI=""
if (( $(awk 'BEGIN {prxint ("'"$MCE_VERSION"'" < 2.4)}') )); then
  echo "MCE version is less than 2.4, use HyperShift command"
  arch=$(arch)
  if [ "$arch" == "x86_64" ]; then
    downURL=$(oc get ConsoleCLIDownload hypershift-cli-download -o json | jq -r '.spec.links[] | select(.text | test("Linux for x86_64")).href') && curl -k --output /tmp/hypershift.tar.gz ${downURL}
    cd /tmp && tar -xvf /tmp/hypershift.tar.gz
    chmod +x /tmp/hypershift
    HCP_CLI="/tmp/hypershift"
    cd -
  fi
else
  echo "MCE version is greater than or equal to 2.4, need to extract HyperShift cli"
  oc extract secret/pull-secret -n openshift-config --to=/tmp --confirm
  HO_IMAGE=$(oc get deployment -n hypershift operator -ojsonpath='{.spec.template.spec.containers[*].image}')
  mkdir /tmp/hs-cli
  brew_registry_auth=$(echo -n "${BREW_IMAGE_REGISTRY_USERNAME}:$(<$BREW_IMAGE_REGISTRY_TOKEN_PATH)" | base64 -w 0)
  echo '{}' | jq --arg auth "$brew_registry_auth" '.auths += {"brew.registry.redhat.io": {"auth": $auth}}' > /tmp/brew_configjson
  oc image extract "brew.${HO_IMAGE}" --path /usr/bin/hypershift-no-cgo:/tmp/hs-cli --registry-config=/tmp/brew_configjson
  chmod +x /tmp/hs-cli/hypershift-no-cgo
  HCP_CLI="/tmp/hs-cli/hypershift-no-cgo"
fi

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

