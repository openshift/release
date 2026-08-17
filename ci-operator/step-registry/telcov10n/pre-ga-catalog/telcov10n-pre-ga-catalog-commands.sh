#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ Fix container user ************"
# Fix user IDs in a container
[ -e "${HOME}/fix_uid.sh" ] && "${HOME}/fix_uid.sh" || echo "${HOME}/fix_uid.sh was not found" >&2

source ${SHARED_DIR}/common-telcov10n-bash-functions.sh

catalog_info_dir=$(mktemp -d)

function update_openshift_config_pull_secret {

  echo "************ telcov10n Add preGA credentials to openshift config pull-secret ************"

  set -x
  oc -n openshift-config get secrets pull-secret -ojson >| /tmp/dot-dockerconfig.json
  cat /tmp/dot-dockerconfig.json | jq -r '.data.".dockerconfigjson"' | base64 -d | jq > /tmp/dot-dockerconfig-data.json
  set +x

  echo "Adding PreGA pull secret to pull the container image index from the Hub cluster..."

  # Extract credentials from vault files for Konflux/dev build registries
  optional_auth_user=$(cat "/var/run/vault/mirror-registry/registry_quay.json" | jq -r '.user')
  optional_auth_password=$(cat "/var/run/vault/mirror-registry/registry_quay.json" | jq -r '.password')
  qe_registry_auth=`echo -n "${optional_auth_user}:${optional_auth_password}" | base64 -w 0`

  openshifttest_auth_user=$(cat "/var/run/vault/mirror-registry/registry_quay_openshifttest.json" | jq -r '.user')
  openshifttest_auth_password=$(cat "/var/run/vault/mirror-registry/registry_quay_openshifttest.json" | jq -r '.password')
  openshifttest_registry_auth=`echo -n "${openshifttest_auth_user}:${openshifttest_auth_password}" | base64 -w 0`

  reg_brew_user=$(cat "/var/run/vault/mirror-registry/registry_brew.json" | jq -r '.user')
  reg_brew_password=$(cat "/var/run/vault/mirror-registry/registry_brew.json" | jq -r '.password')
  brew_registry_auth=`echo -n "${reg_brew_user}:${reg_brew_password}" | base64 -w 0`

  # Note: quay.io/acm-d is NOT included here because the qe_registry_auth credential
  # is for openshift-qe-optional-operators robot which doesn't have access to acm-d.
  # Instead, the registries.conf mirrors point to quay.io/prega/test/acm-d which
  # IS accessible with the quay.io/prega credentials below.
  cat <<EOF >| /tmp/pre-ga.json
{
  "auths": {
    "quay.io/prega": {
      "auth": "$(cat /var/run/telcov10n/ztp-left-shifting/prega-pull-secret)",
      "email": "prega@redhat.com"
    },
    "brew.registry.redhat.io": {
      "auth": "${brew_registry_auth}"
    },
    "quay.io/openshift-qe-optional-operators": {
      "auth": "${qe_registry_auth}"
    },
    "quay.io/openshifttest": {
      "auth": "${openshifttest_registry_auth}"
    }
  }
}
EOF

  jq -s '.[0] * .[1]' \
    /tmp/dot-dockerconfig-data.json \
    /tmp/pre-ga.json \
    >| ${SHARED_DIR}/pull-secret-with-pre-ga.json

  new_dot_dockerconfig_data="$(cat ${SHARED_DIR}/pull-secret-with-pre-ga.json | base64 -w 0)"

  jq '.data.".dockerconfigjson" = "'${new_dot_dockerconfig_data}'"' /tmp/dot-dockerconfig.json | oc replace -f -
}

function apply_catalog_source_and_image_digest_mirror_set {

  local prega_info_dir="${catalog_info_dir}"

  echo
  echo "----------------------------------------------------------------------------------------------"
  echo "--------------------- catalogSource.yaml -------------------------"
  cat "${prega_info_dir}/catalogSource.yaml"
  echo "------------- imageDigestMirrorSet.yaml -----------------"
  cat "${prega_info_dir}/imageDigestMirrorSet.yaml"
  echo "----------------------------------------------------------------------------------------------"

  set -x
  oc -n openshift-marketplace delete catsrc "${CATALOGSOURCE_NAME}" --ignore-not-found

  echo "Remove default catalog source"
  oc patch operatorhub cluster --type=json -p '[{"op": "add", "path": "/spec/sources", "value": [{"name": "redhat-operators", "disabled": true}]}]'
  oc apply -f "${prega_info_dir}/catalogSource.yaml"
  oc apply -f "${prega_info_dir}/imageDigestMirrorSet.yaml"
  cat "${prega_info_dir}/imageDigestMirrorSet.yaml" >| "${SHARED_DIR}/imageDigestMirrorSet.yaml"
  set +x
}

function create_pre_ga_static_catalog_source {
  echo "************ telcov10n Create Pre GA static catalog source ************"

  catalogSource=$(cat <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ${CATALOGSOURCE_NAME}
  namespace: openshift-marketplace
spec:
  image: quay.io/prega/prega-operator-index:v${IMAGE_INDEX_OCP_VERSION}
  displayName: Red Hat Custom Operators Catalog for ${IMAGE_INDEX_OCP_VERSION}
  sourceType: grpc
EOF
)
  export catalogSource
  imageDigestMirrorSet=$(cat <<EOF
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  labels:
    operators.openshift.org/catalog: "true"
  name: prega-operator-index-short
spec:
  imageDigestMirrors:
  # 1. Maps all registry.redhat.io images keeping their exact paths
  # e.g., registry.redhat.io/acm-d/insights-client-rhel9 -> quay.io/prega/test/acm-d/insights-client-rhel9
  - mirrors:
    - quay.io/prega/test
    source: registry.redhat.io

  # 2. Maps the multicluster engine images
  - mirrors:
    - quay.io/prega/test/acm-d
    source: registry.redhat.io/multicluster-engine

  # 3. Maps the RHACM images
  - mirrors:
    - quay.io/prega/test/acm-d
    source: registry.redhat.io/rhacm2
EOF
)
  export imageDigestMirrorSet

  echo "Creating Pre GA static catalog source..."

  echo "${catalogSource}" > "${catalog_info_dir}/catalogSource.yaml"
  echo "${imageDigestMirrorSet}" > "${catalog_info_dir}/imageDigestMirrorSet.yaml"
  echo "Pre GA static catalog source has been created successfully!!!"
}


function create_pre_ga_calatog {

  echo "************ telcov10n Create Pre GA catalog ************"

  create_pre_ga_static_catalog_source

  apply_catalog_source_and_image_digest_mirror_set

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

  if [ -n "${CATALOGSOURCE_NAME:-}" ]; then
    create_pre_ga_calatog
  else
    echo
    echo "No preGA catalog name set. Skipping catalog creation..."
  fi
}

main
