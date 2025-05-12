#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ telcov10n Fix user IDs in a container ************"
[ -e "${HOME}/fix_uid.sh" ] && "${HOME}/fix_uid.sh" || echo "${HOME}/fix_uid.sh was not found" >&2

source ${SHARED_DIR}/common-telcov10n-bash-functions.sh

function set_hub_cluster_kubeconfig {
  echo "************ telcov10n Set Hub kubeconfig from  \${SHARED_DIR}/hub-kubeconfig location ************"
  export KUBECONFIG="${SHARED_DIR}/hub-kubeconfig"
}

function check_git_repo_is_alive {

  echo "************ telcov10n Checking if the Hub cluster is available ************"

  gitea_project="${GITEA_NAMESPACE}"

  echo
  set -x
  oc -n ${gitea_project} get deploy,pod
  set +x
  echo
}

function push_source_crs {

  echo "************ telcov10n Pushing Source CR files ************"

  SPOKE_CLUSTER_NAME=${NAMESPACE}

  gitea_ssh_nodeport_uri="$(cat ${SHARED_DIR}/gitea-ssh-nodeport-uri.txt)"
  ssh_pri_key_file=/tmp/ssh-prikey
  rm -fv ${ssh_pri_key_file}
  cp -v ${SHARED_DIR}/ssh-key-${GITEA_NAMESPACE} ${ssh_pri_key_file}
  chmod 0400 ${ssh_pri_key_file}

  set -x
  ztp_repo_dir=$(mktemp -d --dry-run)
  git config --global user.email "ztp-spoke-cluster@telcov10n.com"
  git config --global user.name "ZTP Spoke Cluster Telco Verification"
  GIT_SSH_COMMAND="ssh -v -o StrictHostKeyChecking=no -i ${ssh_pri_key_file}" git clone ${gitea_ssh_nodeport_uri} ${ztp_repo_dir}
  pushd .
  cd ${ztp_repo_dir}
  mkdir -pv site-policies/${SPOKE_CLUSTER_NAME}
  cp -a ${HOME}/ztp/source-crs site-policies/${SPOKE_CLUSTER_NAME}/
  touch site-policies/${SPOKE_CLUSTER_NAME}/".ts-$(date -u +%s%N)"
  git add .
  git commit -m 'Generated PGT'
  GIT_SSH_COMMAND="ssh -v -o StrictHostKeyChecking=no -i ${ssh_pri_key_file}" git push origin main || {
  GIT_SSH_COMMAND="ssh -v -o StrictHostKeyChecking=no -i ${ssh_pri_key_file}" git pull -r origin main &&
  GIT_SSH_COMMAND="ssh -v -o StrictHostKeyChecking=no -i ${ssh_pri_key_file}" git push origin main ; }
  set +x
  popd
}

function generate_policy_related_files {

  set -x
  policies_path="${1}"

  if [ -n "${CATALOGSOURCE_NAME}" ]; then
    catatlog_index_img="$(oc -n openshift-marketplace get catsrc ${CATALOGSOURCE_NAME} -ojsonpath='{.spec.image}')"
  fi

  ns_padded="000${SPOKE_CLUSTER_NAME}"
  ns_tail="${ns_padded: -4}"

  jq -c '.[]' <<< "$(yq -o json <<< ${PGT_RELATED_FILES})" | while read -r entry; do
    # Extract the filename and content
    filename=$(echo "$entry" | jq -r '.filename')
    content=$(echo "$entry" | jq -r '.content')

    # Create the file and write the content
    echo "mkdir -pv ${policies_path}/$(dirname $filename)"
    echo "cat <<EOPGT >| ${policies_path}/$(basename $filename)"
    if [ "$(echo -e "$content" | yq eval '.kind')" == "PolicyGenTemplate" ]; then
      echo -e "$content" | \
        yq eval '. | select(.metadata.namespace) .metadata.namespace += "'${ns_tail}'"' | \
        yq eval '. | select(.spec.bindingRules) .spec.bindingRules.prowId = "'${SPOKE_CLUSTER_NAME}'"' | \
        yq eval '(.spec.sourceFiles[] | select(.metadata.name == "'${CATALOGSOURCE_NAME:-}'").spec.image) = "'${catatlog_index_img}'"'
    else
      echo -e "$content" | \
        yq eval '. | select(.kind == "Namespace") .metadata.name += "'${ns_tail}'"' | \
        yq eval '. | select(.metadata.namespace) .metadata.namespace += "'${ns_tail}'"' | \
        yq eval '. | select(.spec.bindingRules) .spec.bindingRules.prowId = "'${SPOKE_CLUSTER_NAME}'"'
    fi
    echo "EOPGT"

  done
}

function push_policies {

  echo "************ telcov10n Pushing Policy Gen Templates files ************"

  gitea_ssh_uri="$(cat ${SHARED_DIR}/gitea-ssh-uri.txt)"
  ssh_pri_key_file=${SHARED_DIR}/ssh-key-${GITEA_NAMESPACE}

  run_script=$(mktemp --dry-run)

  cat <<EOF > ${run_script}
set -o nounset
set -o errexit
set -o pipefail

echo "$(cat ${ssh_pri_key_file})" > /tmp/ssh-prikey
chmod 0400 /tmp/ssh-prikey

set -x
ztp_repo_dir=\$(mktemp -d --dry-run)
git config --global user.email "ztp-spoke-cluster@telcov10n.com"
git config --global user.name "ZTP Spoke Cluster Telco Verification"
GIT_SSH_COMMAND="ssh -v -o StrictHostKeyChecking=no -i /tmp/ssh-prikey" git clone ${gitea_ssh_uri} \${ztp_repo_dir}
cd \${ztp_repo_dir}
policies_path="site-policies/${SPOKE_CLUSTER_NAME}"
mkdir -pv \${policies_path}
touch \${policies_path}/.ts-$(date -u +%s%N)
############## BEGIN of Policy GenTemplate files #####################################################
$(generate_policy_related_files "site-policies/${SPOKE_CLUSTER_NAME}")
############## END of Policy GenTemplate files #######################################################

cat \${ztp_repo_dir}/clusters/kustomization.yaml >| \${ztp_repo_dir}/site-policies/kustomization.yaml

git add .
git commit -m 'Generated Policy files'
GIT_SSH_COMMAND="ssh -v -o StrictHostKeyChecking=no -i /tmp/ssh-prikey" git push origin main || {
GIT_SSH_COMMAND="ssh -v -o StrictHostKeyChecking=no -i /tmp/ssh-prikey" git pull -r origin main &&
GIT_SSH_COMMAND="ssh -v -o StrictHostKeyChecking=no -i /tmp/ssh-prikey" git push origin main ; }
EOF

  # cat ${run_script}
  run_script_on_ocp_cluster ${run_script} ${gitea_project}
}

function are_there_polices_to_be_defined {

  num_of_policies=$(jq -c '.[]' <<< "$(yq -o json <<< ${PGT_RELATED_FILES})"|wc -l)
  if [[ "${num_of_policies}" == "0" ]]; then
    echo "no"
  else
    echo "yes"
  fi
}

function main {

  if [[ "$(are_there_polices_to_be_defined)" == "yes" ]]; then
    echo
    echo "Pushing defined policies..."
    echo
    set_hub_cluster_kubeconfig
    check_git_repo_is_alive
    push_source_crs
    push_policies
  else
    echo
    echo "No policies were defined..."
    echo
  fi
}

main
