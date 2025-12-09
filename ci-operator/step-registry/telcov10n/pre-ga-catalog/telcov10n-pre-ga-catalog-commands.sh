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

function append_production_path_idms_entries {
  # This function addresses the PreGA catalog mirror path mismatch issue.
  # PreGA oc-mirror generates IDMS with development registry paths (e.g., acm-d, redhat-user-workloads),
  # but operator CSVs reference production paths (e.g., rhacm2, multicluster-engine, openshift-gitops-1).
  # Without these additional entries, ACM/MCE/GitOps operators will fail with ImagePullBackOff.
  #
  # This fix ensures only ONE node reboot is needed by appending entries to the IDMS
  # before it's applied to the cluster.
  #
  # Reference: .cursor/docs/troubleshooting/prega-catalog-mirror-issue.md

  local idms_file="${1}"

  echo "************ telcov10n Append production path IDMS entries ************"
  echo ""
  echo "Checking if production path entries need to be added to IDMS..."
  echo "This is required because PreGA oc-mirror generates IDMS with development paths (acm-d, redhat-user-workloads)"
  echo "but operator CSVs reference production paths (rhacm2, multicluster-engine, openshift-gitops-1)"
  echo ""

  # Check if the production path entries are already in the IDMS file
  local needs_rhacm2=false
  local needs_mce=false
  local needs_gitops=false

  if ! grep -q "registry.redhat.io/rhacm2" "${idms_file}"; then
    echo "- Missing: registry.redhat.io/rhacm2 (ACM production path)"
    needs_rhacm2=true
  else
    echo "✓ Found: registry.redhat.io/rhacm2"
  fi

  if ! grep -q "registry.redhat.io/multicluster-engine" "${idms_file}"; then
    echo "- Missing: registry.redhat.io/multicluster-engine (MCE production path)"
    needs_mce=true
  else
    echo "✓ Found: registry.redhat.io/multicluster-engine"
  fi

  if ! grep -q "registry.redhat.io/openshift-gitops-1" "${idms_file}"; then
    echo "- Missing: registry.redhat.io/openshift-gitops-1 (GitOps production path)"
    needs_gitops=true
  else
    echo "✓ Found: registry.redhat.io/openshift-gitops-1"
  fi

  # If any entries are missing, append them to the IDMS file
  if [ "${needs_rhacm2}" = true ] || [ "${needs_mce}" = true ] || [ "${needs_gitops}" = true ]; then
    echo ""
    echo "Appending missing production path entries to ${idms_file}..."

    if [ "${needs_rhacm2}" = true ]; then
      cat <<'EOF' >> "${idms_file}"
  - mirrors:
    - quay.io/prega/test/acm-d
    source: registry.redhat.io/rhacm2
EOF
      echo "  ✓ Added registry.redhat.io/rhacm2 → quay.io/prega/test/acm-d"
    fi

    if [ "${needs_mce}" = true ]; then
      cat <<'EOF' >> "${idms_file}"
  - mirrors:
    - quay.io/prega/test/acm-d
    source: registry.redhat.io/multicluster-engine
EOF
      echo "  ✓ Added registry.redhat.io/multicluster-engine → quay.io/prega/test/acm-d"
    fi

    if [ "${needs_gitops}" = true ]; then
      cat <<'EOF' >> "${idms_file}"
  - mirrors:
    - quay.io/prega/test/redhat-user-workloads/rh-openshift-gitops-tenant
    source: registry.redhat.io/openshift-gitops-1
EOF
      echo "  ✓ Added registry.redhat.io/openshift-gitops-1 → quay.io/prega/test/redhat-user-workloads/rh-openshift-gitops-tenant"
    fi

    echo ""
    echo "✓ Production path entries appended successfully"
    echo "  This ensures ACM, MCE, and GitOps operators can pull images from PreGA mirror"
    echo ""
  else
    echo ""
    echo "✓ All required production path IDMS entries already exist in the file. No changes needed."
    echo ""
  fi
}

function apply_catalog_source_and_image_digest_mirror_set {

  SSHOPTS=(-o 'ConnectTimeout=5'
    -o 'StrictHostKeyChecking=no'
    -o 'UserKnownHostsFile=/dev/null'
    -o 'ServerAliveInterval=90'
    -o LogLevel=ERROR
    -i "${CLUSTER_PROFILE_DIR}/ssh-key")

  catalog_info_dir=$(mktemp -d)

  timeout -s 9 30m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" bash -s -- \
    "${PREGA_CATSRC_AND_IDMS_CRS_URL}" "${PREGA_OPERATOR_INDEX_TAGS_URL}" \
    "${catalog_info_dir}" "${IMAGE_INDEX_OCP_VERSION}" << 'EOF'
set -o nounset
set -o errexit
set -o pipefail

set -x
catalog_soruces_url="${1}"
prega_operator_index_tags_url="${2}"
image_index_ocp_version="${4}"
tag_version="v${4}.0"

function findout_manifest_digest {
  # Try Release Canditates
  res=$(curl -sSL "${prega_operator_index_tags_url}?filter_tag_name=like:${tag_version}-rc." | jq -r '
    [ .tags[] ]
    | sort_by(.start_ts)
    | last.manifest_digest')

  # Try Engineer Canditates
  if [ "${res}" == "null" ]; then
    res=$(curl -sSL "${prega_operator_index_tags_url}?filter_tag_name=like:${tag_version}-ec." | jq -r '
      [ .tags[] ]
      | sort_by(.start_ts)
      | last.manifest_digest')

    if [ "${res}" == "null" ]; then
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
    fi
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

  if [ "${image_index_ocp_version/./}" -gt 419 ]; then
    echo ${tag}
  else
    echo ${tag/-/.0-}
  fi
}

selected_manifest_digest=$(findout_manifest_digest)
version_tag=$(get_related_catalogs_and_icsp_manifests)

echo "Checking if the selected tag exists..."
status_code=$(curl -sSL -o /dev/null -w "%{http_code}" "${catalog_soruces_url}/${version_tag}")
if [ "$status_code" -ne 200 ]; then
  echo "Resource not found (HTTP status: $status_code). Getting previous version..."

  # Get all tags from the base URL, filter for tag version, sort, and get the previous one
  next_version=$(curl -sSL "${catalog_soruces_url}" \
    | grep -oP '(?<=href=")[^"]+' \
    | sort -t '-' -k2,2 -k3,3 \
    | grep "${tag_version/.0/}" \
    | awk -F '[-/]' -v tag_ver="$version_tag" '
BEGIN {
    split(tag_ver, a, "[-/]");
    reference_ts = a[2];
    gsub(/T|ci/, "", reference_ts);
}
{
    current_ts = $2
    gsub(/T|ci/, "", current_ts)
    if (current_ts >= reference_ts) {
        # printf("%s > %s = ", current_ts, reference_ts)
        print $0
        exit
    }
}')

  if [ -n "$next_version" ]; then
    echo "Next available version is: $next_version"
    version_tag=${next_version}
  else
    echo "Could not find a previous version."
  fi
fi

info_dir=${3}/${version_tag}
mkdir -pv ${info_dir}
pushd .
cd ${info_dir}

for f in $(curl -sSL ${catalog_soruces_url}/${version_tag}|grep -oP '(?<=href=")[^"]+'|grep 'yaml$'); do
  set -x
  curl -sSLO ${catalog_soruces_url}/${version_tag}/${f}
  set +x
done

set -x
if [ -n "${next_version:-}" ]; then
  stable_img_index="quay.io/prega/prega-operator-index:${tag_version}"
  sed -i "s#^  image:.*#  image: ${stable_img_index}#" catalogSource.yaml
fi
set +x

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
  # Add or update displayName field in catalogSource.yaml under spec section
  if grep -q "displayName:" ${prega_info_dir}/catalogSource.yaml; then
    # Update existing displayName
    sed -i "s/displayName: .*/displayName: ${CATALOGSOURCE_DISPLAY_NAME}/" ${prega_info_dir}/catalogSource.yaml
  else
    # Add displayName field after image field in spec section
    sed -i "/^  image: /a\  displayName: ${CATALOGSOURCE_DISPLAY_NAME}" ${prega_info_dir}/catalogSource.yaml
  fi
  set +x
  echo "--------------------- ${ARTIFACT_DIR}/pre-ga-info/catalogSource.yaml -------------------------"
  cat ${prega_info_dir}/catalogSource.yaml
  echo "------------- ${ARTIFACT_DIR}/pre-ga-info/imageDigestMirrorSet.yaml (BEFORE) -----------------"
  cat ${prega_info_dir}/imageDigestMirrorSet.yaml
  echo "----------------------------------------------------------------------------------------------"

  # Append production path entries to IDMS if needed (ACM/MCE/GitOps)
  append_production_path_idms_entries "${prega_info_dir}/imageDigestMirrorSet.yaml"

  echo "------------- ${ARTIFACT_DIR}/pre-ga-info/imageDigestMirrorSet.yaml (AFTER) ------------------"
  cat ${prega_info_dir}/imageDigestMirrorSet.yaml
  echo "----------------------------------------------------------------------------------------------"
  set -x
  oc apply -f ${prega_info_dir}/catalogSource.yaml
  oc apply -f ${prega_info_dir}/imageDigestMirrorSet.yaml
  cat ${prega_info_dir}/imageDigestMirrorSet.yaml >| ${SHARED_DIR}/imageDigestMirrorSet.yaml
  set +x
}

function create_pre_ga_calatog {

  echo "************ telcov10n Create Pre GA catalog ************"

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
  create_pre_ga_calatog
}

if [ -n "${CATALOGSOURCE_NAME:-}" ]; then
  main
else
  echo
  echo "No preGA catalog name set. Skipping catalog creation..."
fi