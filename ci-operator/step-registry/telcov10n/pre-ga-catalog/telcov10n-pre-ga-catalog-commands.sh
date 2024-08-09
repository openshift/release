#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ Fix container user ************"
# Fix user IDs in a container
[ -e "${HOME}/fix_uid.sh" ] && "${HOME}/fix_uid.sh" || echo "${HOME}/fix_uid.sh was not found" >&2

function wait_until_command_is_ok {
  cmd=$1 ; shift
  [ $# -gt 0 ] && sleep_for=${1} && shift && \
  [ $# -gt 0 ] && max_attempts=${1} && shift
  [ $# -gt 0 ] && exit_non_ok_message=${1} && shift
  for ((attempts = 0 ; attempts <  ${max_attempts:=10} ; attempts++)); do
    echo "Attempting[${attempts}/${max_attempts}]..."
    set -x
    eval "${cmd}" && { set +x ; return ; }
    sleep ${sleep_for:='1m'}
    set +x
  done
  echo ${exit_non_ok_message:="[Fail] The exit condition was not met"}
  exit 1
}

function create_pre_ga_calatog {

  echo "************ telcov10n Create Pre GA catalog ************"

  set -x
  image_index_tag=$(curl -s "${IMAGES_INDEX_URL}" \
    | jq -r '[.tags[] | select(.name | startswith("v'${IMAGE_INDEX_OCP_VERSION}'-"))] | sort_by(.start_ts) | last.name')
  set +x

  oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: $CATALOGSOURCE_NAME
  namespace: openshift-marketplace
  annotations:
    olm.catalogImageTemplate: "${INDEX_IMAGE}:${image_index_tag}"
spec:
  displayName: PreGA Telco Operators
  grpcPodConfig:
    #extractContent:
    #  cacheDir: /tmp/cache
    #  catalogDir: /configs
    memoryTarget: 30Mi
  image: ${INDEX_IMAGE}:${image_index_tag}
  publisher: OpenShift Telco Verification
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 15m
EOF

  wait_until_command_is_ok \
    "oc -n openshift-marketplace get catalogsource ${CATALOGSOURCE_NAME} -o=jsonpath='{.status.connectionState.lastObservedState}' | grep -w READY" \
    "30s" \
    "20" \
    "Fail to create ${CATALOGSOURCE_NAME} CatalogSource"
  
  set -x
  oc -n openshift-marketplace get catalogsources.operators.coreos.com ${CATALOGSOURCE_NAME}
  set +x
  
  echo
  echo "The ${CATALOGSOURCE_NAME} CatalogSource has been created successfully!!!"
}

function main {
  create_pre_ga_calatog
}

main
