#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig
PULL_SECRET_FILE=${PULL_SECRET_FILE:="${CLUSTER_PROFILE_DIR}/pull-secret"}
CLOUD_PULL_SECRET=$(jq '{ "cloud.openshift.com": .auths["cloud.openshift.com"] }' ${PULL_SECRET_FILE})
UPDATED_PULL_SECRET_FILE="${SHARED_DIR}/pull-secret-new"
CLUSTER_PULL_SECRET="${SHARED_DIR}/cluster-pull-secret"
CLUSTER_UUID=$(oc get clusterversion version -o jsonpath='{.spec.clusterID}{"\n"}')
oc get secrets pull-secret -n openshift-config -o template='{{index .data ".dockerconfigjson"}}' | base64 -d > ${CLUSTER_PULL_SECRET}
jq ".auths += ${CLOUD_PULL_SECRET}" < ${CLUSTER_PULL_SECRET} > ${UPDATED_PULL_SECRET_FILE}
oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=${UPDATED_PULL_SECRET_FILE}
echo $CLUSTER_UUID > ${SHARED_DIR}/cluster_uuid