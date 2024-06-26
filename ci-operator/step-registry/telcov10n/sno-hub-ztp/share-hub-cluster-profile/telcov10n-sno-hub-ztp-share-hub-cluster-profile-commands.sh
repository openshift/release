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
    "${KUBECONFIG}"
    "${KUBEADMIN_PASSWORD_FILE}"
    "${CLUSTER_PROFILE_DIR}"
  )

  cluster_profile_shared_folder=/var/builds/${NAMESPACE}/${SHARED_HUB_CLUSTER_PROFILE}

  echo
  set -x
  rsync -avP --delete-before \
    -e "ssh $(echo "${SSHOPTS[@]}")" \
    "${hub_to_spoke_artifacts[@]}" \
    "root@${AUX_HOST}":${cluster_profile_shared_folder}
  set +x
  echo
}

function create_symbolic_link_to_shared_hub_cluster_profile_artifacts_folder {
  
  echo "************ telcov10n Create a symbolic link to the shared artifacts folder that would be used during Spoke deployments ************"

  cluster_profile_symbolic_link=/var/telco-qe-preserved/${SHARED_HUB_CLUSTER_PROFILE}

  timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" bash -s --  \
  "${cluster_profile_shared_folder}" "${cluster_profile_symbolic_link}" << 'EOF'
set -o nounset
set -o errexit
set -o pipefail

mkdir -p $(dirname ${2})
link -sf ${$1} ${2}
EOF
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
