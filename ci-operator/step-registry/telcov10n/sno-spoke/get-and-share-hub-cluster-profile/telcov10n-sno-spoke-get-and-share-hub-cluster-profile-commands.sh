#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ telcov10n Fix user IDs in a container ************"
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

function append_pr_tag_cluster_profile_artifacts {

  # Just in case of running this script being part of a Pull Request
  if [ -n "${PULL_NUMBER:-}" ]; then
    echo "************ telcov10n Append the 'pr-${PULL_NUMBER}' tag to '${SHARED_HUB_CLUSTER_PROFILE}' folder ************"
    # shellcheck disable=SC2153
    SHARED_HUB_CLUSTER_PROFILE="${SHARED_HUB_CLUSTER_PROFILE}-pr-${PULL_NUMBER}"
  fi
}

function get_hub_cluster_profile_artifacts {

  echo "************ telcov10n Get Hub cluster profile stored from AUX_HOST location ************"

  local_hub_cluster_profile=$(mktemp -d)

  echo
  set -x
  rsync -avP \
    -e "ssh $(echo "${SSHOPTS[@]}")" \
    "root@${AUX_HOST}":/var/builds/telco-qe-preserved/${SHARED_HUB_CLUSTER_PROFILE}/ \
    ${local_hub_cluster_profile}

  ls -Rl ${local_hub_cluster_profile}

  set +x
  echo
}

function share_hub_cluster_profile {
  echo "************ telcov10n Share the Hub cluster profile to be used in later steps ************"
  cp -v $local_hub_cluster_profile/* ${SHARED_DIR}/
}

function main {
  setup_aux_host_ssh_access
  append_pr_tag_cluster_profile_artifacts
  get_hub_cluster_profile_artifacts
  share_hub_cluster_profile
}

main
