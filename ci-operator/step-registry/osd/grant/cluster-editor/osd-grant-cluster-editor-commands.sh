#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

: "${CLUSTER_SECRET:=osd-secret}"
: "${CLUSTER_SECRET_NS:=test-secrets}"
: "${CLUSTER_EDITOR_PREFIX:=cluster-editor-}"
: "${CLUSTER_EDITOR_STRATEGY:=any}" # any | unused (not yet supported)

error() {
  echo "[ERROR] ${1}"
  exit 1
}

read_profile_file() {
  local file="${1}"
  # shellcheck disable=SC2153
  if [[ -f "${CLUSTER_PROFILE_DIR}/${file}" ]]; then
    cat "${CLUSTER_PROFILE_DIR}/${file}"
  fi
}

get_cluster_id() {
  local cluster_id_var="${1}"
  local cluster_id_file="${2}"
  local cluster_id="${!cluster_id_var:-}"
  if [[ ! -n "${cluster_id}" ]]; then
    if [[ -f "${cluster_id_file}" ]]; then
      cluster_id=$(cat "${cluster_id_file}")
    fi
  fi
  echo "${cluster_id}"
}

get_cluster_editor_name() {
  local file="${1:-}"
  local filename
  if [[ -n "${file}" ]]; then
    filename=$(basename "${file}")
    echo "${filename#${CLUSTER_EDITOR_PREFIX}}"
  else
    while read line; do
      get_cluster_editor_name "${line}"
    done
  fi
}

get_cluster_editors() {
  local cluster_profile_dir="${1}"
  local cluster_editor_prefix="${2}"
  find -L "${cluster_profile_dir}" -maxdepth 1 -type f -name "${cluster_editor_prefix}*" | get_cluster_editor_name
}

select_cluster_editor() {
  local cluster_editors="${1}"
  local cluster_editor_strategy="${2}"
  local cluster_editor=""
  cluster_editor_strategy=$(echo "${cluster_editor_strategy}" | tr '[:upper:]' '[:lower:]')
  case "${cluster_editor_strategy}" in
    "any")
      cluster_editor=$(echo "${cluster_editors}" | shuf -n 1)
      ;;
    # TODO: Implement 'unsed' strategy
    # The 'unused' strategy will find an user which is not assigned to any OSD cluster.
    # This approach ensure that tests will not damage other clusters.
  esac
  echo "${cluster_editor}"
}

ocm_login() {
  local sso_client_id
  local sso_client_secret
  local ocm_token
  sso_client_id=$(read_profile_file "sso-client-id")
  sso_client_secret=$(read_profile_file "sso-client-secret")
  ocm_token=$(read_profile_file "ocm-token")
  if [[ ! -z "${sso_client_id}" && ! -z "${sso_client_secret}" ]]; then
    echo "Logging into ${OCM_LOGIN_URL} with SSO credentials"
    ocm login --url "${OCM_LOGIN_URL}" --client-id "${sso_client_id}" --client-secret "${sso_client_secret}"
  elif [[ ! -z "${ocm_token}" ]]; then
    echo "Logging into ${OCM_LOGIN_URL} with OCM token"
    ocm login --url "${OCM_LOGIN_URL}" --token "${ocm_token}"
  else
    error "Cannot login! You need to specify sso_client_id/sso_client_secret or ocm_token in the CLUSTER_PROFILE_DIR!"
  fi
}

ocm_check_cluster_editor() {
  local cluster_editor
  local token
  local response
  local username
  cluster_editor="${1}"
  token=$(read_profile_file "${CLUSTER_EDITOR_PREFIX}${cluster_editor}")
  response=$(ocm login --url "${OCM_LOGIN_URL}" --token "${token}" 2>&1 && ocm whoami)
  if ( ! echo "${response}" | jq -e > /dev/null 2>&1 ); then
    echo "${response}"
    return 1
  fi
  username=$(echo "${response}" | jq -r '.username')
  if [[ "${cluster_editor}" != "${username}" ]]; then
    echo "Cluster editor name '${cluster_editor}' doesn't match the real username '${username}'"
    return 1
  fi
}

ocm_grant_cluster_editor_role() {
  local cluster_id
  local cluster_editor
  local subscription_href
  local request_json 
  ocm_login
  cluster_id="${1}"
  cluster_editor="${2}"
  subscription_href=$(ocm get "/api/clusters_mgmt/v1/clusters/${cluster_id}" | jq -r '.subscription.href')
  request_json="{\"account_username\": \"${cluster_editor}\", \"role_id\": \"ClusterEditor\"}"
  echo "Grant ClusterEditor role to ${cluster_editor}"
  echo "${request_json}" | ocm post "${subscription_href}/role_bindings"
}

oc_share_cluster_editor_token() {
  local kubeconfig_file
  local cluster_editor
  local cluster_editor_token
  kubeconfig_file="${1}"
  cluster_editor="${2}"
  cluster_editor_token=$(read_profile_file "${CLUSTER_EDITOR_PREFIX}${cluster_editor}")
  # make sure the namespace CLUSTER_SECRET_NS exists
  echo "Create namespace ${CLUSTER_SECRET_NS}"
  KUBECONFIG="${kubeconfig_file}" oc create ns "${CLUSTER_SECRET_NS}" --dry-run=client -o yaml | oc apply -f -
  # create or update the OCM_TOKEN in CLUSTER_SECRET
  echo "Create secret ${CLUSTER_SECRET} with key OCM_TOKEN"
  KUBECONFIG="${kubeconfig_file}" oc create secret generic "${CLUSTER_SECRET}" --namespace="${CLUSTER_SECRET_NS}" --from-literal=OCM_TOKEN="${cluster_editor_token}" --dry-run=client -o yaml | oc apply -f -
}

main() {
  local cluster_id
  local cluster_editor
  local cluster_editors
  cluster_id=$(get_cluster_id "CLUSTER_ID" "${SHARED_DIR}/cluster-id")
  if [[ ! -n "${cluster_id}" ]]; then
    error "Cluster id is not defined!"
  fi
  echo "Cluster id: ${cluster_id}"

  local kubeconfig="${SHARED_DIR}/kubeconfig"
  if [[ ! -n "${kubeconfig}" ]]; then
    error "Cannot find kubeconfig!"
  fi
  echo "Kubeconfig: ${kubeconfig}"

  echo "Cluster editor prefix: ${CLUSTER_EDITOR_PREFIX}"
  cluster_editors=$(get_cluster_editors "${CLUSTER_PROFILE_DIR}" "${CLUSTER_EDITOR_PREFIX}")
  echo "Cluster editors: ${cluster_editors:-no cluster editors found}"

  echo "Cluster editor strategy: ${CLUSTER_EDITOR_STRATEGY}"
  cluster_editor=$(select_cluster_editor "${cluster_editors}" "${CLUSTER_EDITOR_STRATEGY}")
  echo "Cluster editor: ${cluster_editor:-no cluster editor was selected}"

  local cluster_editor_check
  if [[ -n "${cluster_editor}" ]]; then
    cluster_editor_check=$(ocm_check_cluster_editor "${cluster_editor}")
     if [[ -n "${cluster_editor_check}" ]]; then
      error "${cluster_editor_check}"
    fi
    # Grant ClusterEditor role on OSD via ocm
    ocm_grant_cluster_editor_role "${cluster_id}" "${cluster_editor}"
    # Share the appropriate secret on openshift via oc
    oc_share_cluster_editor_token "${kubeconfig}" "${cluster_editor}"
  fi
}

# Sourceable from *test.sh files and bats
if [[ ${0} != *"test.sh" && ${0} != *"bats-exec"* ]]; then
  main "$@"
  exit 0
fi
