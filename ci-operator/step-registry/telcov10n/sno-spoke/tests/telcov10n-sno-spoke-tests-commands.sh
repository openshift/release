#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ telcov10n cluster setup via agent command ************"
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

# function set_expiration_time {

#   echo "************ telcov10n Set Hub cluster expiration time ************"

#   echo
#   set -x
#   b64_exp_time=$(echo "${EXPIRATION_TIME}" | base64 -w 0)
#   timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" bash -s --  \
#   "${NAMESPACE}" "${b64_exp_time}" "${EXPIRATION_TIME_FILE}" "${SHARED_HUB_CLUSTER_PROFILE}" << 'EOF'
# set -o nounset
# set -o errexit
# set -o pipefail

# exp_time_ns_file=/var/builds/${1}
# exp_time=$(echo ${2} | base64 -d)
# shared_exp_time_ns_file_sym_link=${3}
# cluster_profile_folder=$(dirname ${exp_time_ns_file})/${1}-cluster_profile_dir
# shared_cluster_profile_folder=${4}

# mkdir -pv $(dirname ${exp_time_ns_file})
# mkdir -pv ${cluster_profile_folder}

# TZ=UTC date --iso-8601=seconds -d "${exp_time}" > ${exp_time_ns_file}

# ln -sf ${exp_time_ns_file} ${shared_exp_time_ns_file_sym_link}
# ln -sf ${cluster_profile_folder} ${shared_cluster_profile_folder}

# echo "Now       : $(TZ=UTC date --iso-8601=seconds)"
# echo "Expire at : $(cat ${3}) [save at ${3} file]"
# EOF

#   set +x
#   echo
# }

function save_cluster_profile_artifacts {

  echo "************ telcov10n Save those artifacts that will be used during Spoke deployments ************"

  hub_to_spoke_artifacts=(
    "${KUBECONFIG}"
    "${KUBEADMIN_PASSWORD_FILE}"
    "${CLUSTER_PROFILE_DIR}"
  )

  echo
  set -x
  rsync -avP \
    -e "ssh $(echo "${SSHOPTS[@]}")" \
    "${hub_to_spoke_artifacts[@]}" \
    "root@${AUX_HOST}":${SHARED_HUB_CLUSTER_PROFILE}/
  set +x
  echo
}

function run_tests {
  setup_aux_host_ssh_access
  # set_expiration_time
  # save_cluster_profile_artifacts
}

function pull_request_debug {

  echo "Using pull request ${PULL_NUMBER}... DO NOT preserve the hub cluster"

  echo "######################################################################"
  echo "# From here WIP changes"
  echo "######################################################################"
  echo " To quit, run the following command from POD shell: "
  echo " $ touch debug.done"
  echo "######################################################################"
  echo

  # set -x
  # oc get no,clusterversion,mcp,co,sc,pv
  # oc get subscriptions.operators,OperatorGroup,pvc -A
  # oc whoami --show-console
  # set +x
  echo "Current namespace is ${NAMESPACE} for Spoke testing"

  set -x
  while sleep 1m; do
    date
    test -f debug.done && exit 0
  done

}

if [ -n "${PULL_NUMBER:-}" ]; then
  pull_request_debug
else
  run_tests
fi
