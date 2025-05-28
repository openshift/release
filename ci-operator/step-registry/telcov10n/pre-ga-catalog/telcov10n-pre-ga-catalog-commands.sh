#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ Fix container user ************"
# Fix user IDs in a container
[ -e "${HOME}/fix_uid.sh" ] && "${HOME}/fix_uid.sh" || echo "${HOME}/fix_uid.sh was not found" >&2

source ${SHARED_DIR}/common-telcov10n-bash-functions.sh

function update_openshift_config_pull_secret {

  echo "************ telcov10n Add preGA credentials to openshift config pull-secret ************"

  set -x
  oc -n openshift-config get secrets pull-secret -ojson >| /tmp/dot-dockerconfig.json
  cat /tmp/dot-dockerconfig.json | jq -r '.data.".dockerconfigjson"' | base64 -d | jq > /tmp/dot-dockerconfig-data.json
  set +x

  echo "Adding PreGA pull secret to pull the container image index from the Hub cluster..."

  # optional_auth_user=$(cat "/var/run/vault/mirror-registry/registry_quay.json" | jq -r '.user')
  # optional_auth_password=$(cat "/var/run/vault/mirror-registry/registry_quay.json" | jq -r '.password')
  # qe_registry_auth=`echo -n "${optional_auth_user}:${optional_auth_password}" | base64 -w 0`

  # openshifttest_auth_user=$(cat "/var/run/vault/mirror-registry/registry_quay_openshifttest.json" | jq -r '.user')
  # openshifttest_auth_password=$(cat "/var/run/vault/mirror-registry/registry_quay_openshifttest.json" | jq -r '.password')
  # openshifttest_registry_auth=`echo -n "${openshifttest_auth_user}:${openshifttest_auth_password}" | base64 -w 0`

  # reg_brew_user=$(cat "/var/run/vault/mirror-registry/registry_brew.json" | jq -r '.user')
  # reg_brew_password=$(cat "/var/run/vault/mirror-registry/registry_brew.json" | jq -r '.password')
  # brew_registry_auth=`echo -n "${reg_brew_user}:${reg_brew_password}" | base64 -w 0`

#   cat <<EOF >| /tmp/pre-ga.json
# {
#   "auths": {
#     "quay.io/prega": {
#       "auth": "$(cat /var/run/telcov10n/ztp-left-shifting/prega-pull-secret)",
#       "email": "prega@redhat.com"
#     },
#     "brew.registry.redhat.io": {
#       "auth": "${brew_registry_auth}"
#     },
#     "quay.io/openshift-qe-optional-operators": {
#       "auth": "${qe_registry_auth}"
#     },
#     "quay.io/openshifttest": {
#       "auth": "${openshifttest_registry_auth}"
#     }
#   }
# }
# EOF

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

  jq -s '.[0] * .[1]' \
    /tmp/dot-dockerconfig-data.json \
    /tmp/pre-ga.json \
    >| ${SHARED_DIR}/pull-secret-with-pre-ga.json

  new_dot_dockerconfig_data="$(cat ${SHARED_DIR}/pull-secret-with-pre-ga.json | base64 -w 0)"

  jq '.data.".dockerconfigjson" = "'${new_dot_dockerconfig_data}'"' /tmp/dot-dockerconfig.json | oc replace -f -
}

function apply_catalog_source_and_image_content_source_policy {

  image_index_tag="v${IMAGE_INDEX_OCP_VERSION}.0"

  SSHOPTS=(-o 'ConnectTimeout=5'
    -o 'StrictHostKeyChecking=no'
    -o 'UserKnownHostsFile=/dev/null'
    -o 'ServerAliveInterval=90'
    -o LogLevel=ERROR
    -i "${CLUSTER_PROFILE_DIR}/ssh-key")

  catalog_info_dir=$(mktemp -d)

  timeout -s 9 30m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" bash -s -- \
    "${PREGA_CATSRC_AND_ICSP_CRS_URL}" "${PREGA_OPERATOR_INDEX_TAGS_URL}" \
    "${catalog_info_dir}" "${image_index_tag}" << 'EOF'
set -o nounset
set -o errexit
set -o pipefail

set -x
catalog_soruces_url="${1}"
prega_operator_index_tags_url="${2}"
tag_version="${4}"

function findout_manifest_digest {
  res=$(curl -sSL "${prega_operator_index_tags_url}?specificTag=${tag_version}" | jq -r '
    [ .tags[] ]
    | sort_by(.start_ts)
    | last.manifest_digest')

  if [ "${res}" == "null" ]; then
    res=$(curl -sSL "${prega_operator_index_tags_url}?filter_tag_name=like:${tag_version/.0/-}" | jq -r '
      [ .tags[]
      | select(has("end_ts") | not)]
      | sort_by(.start_ts)
      | .[-2].manifest_digest')
  fi

  echo "${res}"
}

function get_related_catalogs_and_icsp_manifests {

  query_tag="${tag_version%.*}-"

  for ((page = 1 ; page < ${max_pages:=50}; page++)); do

    index_list=$(curl -sSL "${prega_operator_index_tags_url}/?filter_tag_name=like:${query_tag}&page=${page}" | jq)

    tag=$(echo "${index_list}" | jq -r '
      [.tags[]
      | select(.manifest_digest == "'${selected_manifest_digest}'")]
      | first.name')
    [ "${tag}" != "null" ] && break
    tag="${selected_manifest_digest}-not-found"

    has_additional=$(echo "${index_list}" | jq -r '.has_additional')
    [ "${has_additional}" == "false" ] && break
  done

  echo ${tag/-/.0-}
}

selected_manifest_digest=$(findout_manifest_digest)
version_tag=$(get_related_catalogs_and_icsp_manifests)
info_dir=${3}/${version_tag}

mkdir -pv ${info_dir}
pushd .
cd ${info_dir}

for f in $(curl -sSL ${catalog_soruces_url}/${version_tag}|grep -oP '(?<=href=")[^"]+'|grep 'yaml$'); do
  set -x
  curl -sSLO ${catalog_soruces_url}/${version_tag}/${f}
  set +x
done

popd
EOF

  rsync -avP \
      -e "ssh $(echo "${SSHOPTS[@]}")" \
      "root@${AUX_HOST}":${catalog_info_dir}/ \
      ${catalog_info_dir}

  timeout -s 9 30m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" bash -s -- \
    "${catalog_info_dir}" << 'EOF'
set -o nounset
set -o errexit
set -o pipefail

set -x
rm -frv ${1}
EOF

  echo
  echo "----------------------------------------------------------------------------------------------"
  set -x
  rm -frv "${ARTIFACT_DIR}/pre-ga-info"
  mv -v ${catalog_info_dir} "${ARTIFACT_DIR}/pre-ga-info"
  prega_info_dir="$(ls -1d ${ARTIFACT_DIR}/pre-ga-info/*)"
  ls -lhrtR ${prega_info_dir}
  set +x
  echo
  echo "----------------------------------------------------------------------------------------------"
  echo
  set -x
  oc -n openshift-marketplace delete catsrc ${CATALOGSOURCE_NAME} --ignore-not-found
  sed -i "s/name: .*/name: ${CATALOGSOURCE_NAME}/" ${prega_info_dir}/catalogSource.yaml
  sed -i "s/displayName: .*/displayName: ${CATALOGSOURCE_DISPLAY_NAME}/" ${prega_info_dir}/catalogSource.yaml
  set +x
  echo "--------------------- ${ARTIFACT_DIR}/pre-ga-info/catalogSource.yaml -------------------------"
  cat ${prega_info_dir}/catalogSource.yaml
  echo "------------- ${ARTIFACT_DIR}/pre-ga-info/imageContentSourcePolicy.yaml ----------------------"
  cat ${prega_info_dir}/imageContentSourcePolicy.yaml
  echo "----------------------------------------------------------------------------------------------"
  set -x
  oc apply -f ${prega_info_dir}/catalogSource.yaml
  oc apply -f ${prega_info_dir}/imageContentSourcePolicy.yaml
  cat ${prega_info_dir}/imageContentSourcePolicy.yaml >| ${SHARED_DIR}/imageContentSourcePolicy.yaml
  set +x
}

function create_pre_ga_calatog {

  echo "************ telcov10n Create Pre GA catalog ************"

  apply_catalog_source_and_image_content_source_policy

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