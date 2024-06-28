#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ Fix container user ************"
# Fix user IDs in a container
[ -e "${HOME}/fix_uid.sh" ] && "${HOME}/fix_uid.sh" || echo "${HOME}/fix_uid.sh was not found" >&2

function setup_aux_host_ssh_access {

  echo "************ telcov10n Setup AUX_HOST SSH access ************"

  SSHOPTS=(
    -o 'ConnectTimeout=5'
    -o 'StrictHostKeyChecking=no'
    -o 'UserKnownHostsFile=/dev/null'
    -o 'ServerAliveInterval=90'
    -o LogLevel=ERROR
    -i "${CLUSTER_PROFILE_DIR}/ssh-key"
  )

}

function save_hub_cluster_profile_artifacts {

  echo "************ telcov10n Save those artifacts that will be used during Spoke deployments ************"

  hub_to_spoke_artifacts=(
    "$(readlink -f ${KUBECONFIG})"
    "$(readlink -f ${KUBEADMIN_PASSWORD_FILE})"
    "$(readlink -f ${CLUSTER_PROFILE_DIR}/pull-secret)"
    "$(readlink -f ${CLUSTER_PROFILE_DIR}/base_domain)"
  )

  local_cluster_profile_shared_folder=$(mktemp -d --dry-run)/${SHARED_HUB_CLUSTER_PROFILE}
  mkdir -pv ${local_cluster_profile_shared_folder}
  cp -av "${hub_to_spoke_artifacts[@]}" ${local_cluster_profile_shared_folder}/

  echo
  set -x
  rsync -avP --delete-before \
    -e "ssh $(echo "${SSHOPTS[@]}")" \
    "${local_cluster_profile_shared_folder}" \
    "root@${AUX_HOST}":/var/builds/${NAMESPACE}
  set +x
  echo
}

function create_symbolic_link_to_shared_hub_cluster_profile_artifacts_folder {
  
  echo "************ telcov10n Create a symbolic link to the shared artifacts folder that would be used during Spoke deployments ************"

  ln -s /var/builds/${NAMESPACE}/${SHARED_HUB_CLUSTER_PROFILE} ${SHARED_HUB_CLUSTER_PROFILE}

  echo
  set -x
  rsync -avP \
    -e "ssh $(echo "${SSHOPTS[@]}")" \
    "${SHARED_HUB_CLUSTER_PROFILE}" \
    "root@${AUX_HOST}":/var/telco-qe-preserved/
  set +x
  echo
}

function pull_request_debug {

  echo "Using pull request ${PULL_NUMBER}, so this Hub cluster won't be preserved"

  echo "######################################################################"
  echo "# From here WIP changes"
  echo "######################################################################"
  echo " To quit, run the following command from POD shell: "
  echo " $ touch ${HOME}/debug.done"
  echo "######################################################################"
  echo

  set -x
  oc get no,clusterversion,mcp,co,sc,pv
  oc get subscriptions.operators,OperatorGroup,pvc -A
  oc whoami --show-console
  set +x
  echo "Current OCP Hub cluster namespace is ${NAMESPACE}"

  set -x
  while sleep 1m; do
    date
    test -f ${HOME}/debug.done && break
  done

}

function main {
  setup_aux_host_ssh_access
  save_hub_cluster_profile_artifacts
  create_symbolic_link_to_shared_hub_cluster_profile_artifacts_folder
}

main

if [ -n "${PULL_NUMBER:-}" ]; then
  pull_request_debug
fi
