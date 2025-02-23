#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ telcov10n Fix user IDs in a container ************"
[ -e "${HOME}/fix_uid.sh" ] && "${HOME}/fix_uid.sh" || echo "${HOME}/fix_uid.sh was not found" >&2

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

function run_script_in_the_hub_cluster {
  local helper_img="${GITEA_HELPER_IMG}"
  local script_file=$1
  shift && local ns=$1
  [ $# -gt 1 ] && shift && local pod_name="${1}"

  set -x
  if [[ "${pod_name:="--rm hub-script"}" != "--rm hub-script" ]]; then
    oc -n ${ns} get pod ${pod_name} 2> /dev/null || {
      oc -n ${ns} run ${pod_name} \
        --image=${helper_img} --restart=Never -- sleep infinity ; \
      oc -n ${ns} wait --for=condition=Ready pod/${pod_name} --timeout=10m ;
    }
    oc -n ${ns} exec -i ${pod_name} -- \
      bash -s -- <<EOF
$(cat ${script_file})
EOF
  [ $# -gt 1 ] && oc -n ${ns} delete pod ${pod_name}
  else
    oc -n ${ns} run -i ${pod_name} \
      --image=${helper_img} --restart=Never -- \
        bash -s -- <<EOF
$(cat ${script_file})
EOF
  fi
  set +x
}

function push_source_crs {

  echo "************ telcov10n Pushing Source CR files ************"

  gitea_ssh_nodeport_uri="$(cat ${SHARED_DIR}/gitea-ssh-nodeport-uri.txt)"
  ssh_pri_key_file=/tmp/ssh-prikey
  cp -v ${SHARED_DIR}/ssh-key-${GITEA_NAMESPACE} ${ssh_pri_key_file}
  chmod 0400 ${ssh_pri_key_file}

  set -x
  ztp_repo_dir=$(mktemp -d --dry-run)
  git config --global user.email "ztp-spoke-cluster@telcov10n.com"
  git config --global user.name "ZTP Spoke Cluster Telco Verification"
  GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=no -i ${ssh_pri_key_file}" git clone ${gitea_ssh_nodeport_uri} ${ztp_repo_dir}
  pushd .
  cd ${ztp_repo_dir}
  mkdir -pv site-policies
  cp -a ${HOME}/ztp/source-crs site-policies/
  git add .
  git commit -m 'Generated PGT'
  GIT_SSH_COMMAND="ssh -v -o StrictHostKeyChecking=no -i ${ssh_pri_key_file}" git push origin main
  popd
}

function generate_policy_related_files {

  jq -c '.[]' <<< "$(yq -o json <<< ${PGT_RELATED_FILES})" | while read -r entry; do
    # Extract the filename and content
    filename=$(echo "$entry" | jq -r '.filename')
    content=$(echo "$entry" | jq -r '.content')

    # Create the file and write the content
    echo "mkdir -pv $(dirname $filename)"
    echo "cat <<EOPGT >| $filename"
    echo -e "$content"
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
GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=no -i /tmp/ssh-prikey" git clone ${gitea_ssh_uri} \${ztp_repo_dir}
cd \${ztp_repo_dir}
rm -fv .placeholder*
touch .placeholder-$(date +%s)
############## BEGIN of Policy GenTemplate files #####################################################
$(generate_policy_related_files)
############## END of Policy GenTemplate files #######################################################
git add .
git commit -m 'Generated Policy files'
GIT_SSH_COMMAND="ssh -v -o StrictHostKeyChecking=no -i /tmp/ssh-prikey" git push origin main
EOF

  # cat ${run_script}
  run_script_in_the_hub_cluster ${run_script} ${gitea_project}
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
    generate_policy_related_files
    push_policies
  else
    echo
    echo "No policies were defined..."
    echo
  fi
}

main
