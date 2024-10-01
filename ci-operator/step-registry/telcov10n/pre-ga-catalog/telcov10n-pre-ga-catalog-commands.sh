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

function update_openshift_config_pull_secret {

  echo "************ telcov10n Add preGA credentials to openshift config pull-secret ************"

  set -x
  oc -n openshift-config get secrets pull-secret -ojson >| /tmp/dot-dockerconfig.json
  cat /tmp/dot-dockerconfig.json | jq -r '.data.".dockerconfigjson"' | base64 -d | jq > /tmp/dot-dockerconfig-data.json
  set +x

  echo "Adding PreGA pull secret to pull the container image index from the Hub cluster..."

  cat <<EOF >| /tmp/pre-ga.json
{
  "auths": {
    "quay.io/prega": {
      "auth": "$(cat /var/run/telcov10n/ztp-left-shifting/prega-pull-secret)",
      "email": "prega@redhat.com"
    }
  }
}
EOF

  new_dot_dockerconfig_data=$(jq -s '.[0] * .[1]' \
    /tmp/dot-dockerconfig-data.json \
    /tmp/pre-ga.json \
    | base64 -w 0)

  jq '.data.".dockerconfigjson" = "'${new_dot_dockerconfig_data}'"' /tmp/dot-dockerconfig.json | oc replace -f -
}

function create_pre_ga_calatog {

  echo "************ telcov10n Create Pre GA catalog ************"

  set -x
  image_index_tag="v${IMAGE_INDEX_OCP_VERSION}.0"
  oc -n openshift-marketplace delete catsrc $CATALOGSOURCE_NAME --ignore-not-found
  set +x

  oc create -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: $CATALOGSOURCE_NAME
  namespace: openshift-marketplace
  annotations:
    olm.catalogImageTemplate: "${INDEX_IMAGE}:${image_index_tag}"
spec:
  displayName: PreGA Telco Operators
  nodeSelector:
    kubernetes.io/os: linux
    node-role.kubernetes.io/master: ""
  priorityClassName: system-cluster-critical
  securityContextConfig: restricted
  tolerations:
  - effect: NoSchedule
    key: node-role.kubernetes.io/master
    operator: Exists
  - effect: NoExecute
    key: node.kubernetes.io/unreachable
    operator: Exists
    tolerationSeconds: 120
  - effect: NoExecute
    key: node.kubernetes.io/not-ready
    operator: Exists
    tolerationSeconds: 120
  image: ${INDEX_IMAGE}:${image_index_tag}
  priority: -100
  publisher: OpenShift Telco Verification
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 10m
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
  set -x
  oc -n openshift-marketplace get catalogsources.operators.coreos.com ${CATALOGSOURCE_NAME} -oyaml
  set +x

  echo
  echo "The ${CATALOGSOURCE_NAME} CatalogSource has been created successfully!!!"
}

function main {
  update_openshift_config_pull_secret
  create_pre_ga_calatog
}

if [ -n "${CATALOGSOURCE_NAME:-}" ]; then
  main
else
  echo
  echo "No preGA catalog name set. Skipping catalog creation..."
fi