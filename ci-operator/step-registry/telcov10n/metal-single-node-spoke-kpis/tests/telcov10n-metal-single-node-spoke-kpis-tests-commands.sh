#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ telcov10n Fix user IDs in a container ************"
[ -e "${HOME}/fix_uid.sh" ] && "${HOME}/fix_uid.sh" || echo "${HOME}/fix_uid.sh was not found" >&2

source ${SHARED_DIR}/common-telcov10n-bash-functions.sh

function set_spoke_cluster_kubeconfig {

  echo "************ telcov10n Set Spoke kubeconfig ************"

  SPOKE_CLUSTER_NAME=${NAMESPACE}
  secret_kubeconfig=${SPOKE_CLUSTER_NAME}-admin-kubeconfig
  secret_adm_pass=${SPOKE_CLUSTER_NAME}-admin-password

  export KUBECONFIG="${SHARED_DIR}/spoke-${secret_kubeconfig}.yaml"

  if [ -n "${SOCKS5_PROXY}" ]; then
    _curl="curl -x ${SOCKS5_PROXY}"
  else
    _curl="curl"
  fi
}

function test_spoke_cluster_repo {

  echo "************ telcov10n Clone and verify spoke_cluster repo ************"

  run_script=$(mktemp --dry-run)

  cat <<EOF > ${run_script}
set -o nounset
set -o errexit
set -o pipefail

set -x
date -u
uname -a
ls -l
EOF

  spoke_cluster_project="default"
  run_script_on_ocp_cluster ${run_script} ${spoke_cluster_project} "${NAMESPACE}-test-helper" "done"
}

function test_spoke_deployment {

  echo "************ telcov10n Check Spoke Cluster ************"

  # Add here all the verifications needed.
  # The following lines are just a naive example that check web console and
  # run a script inside a POD in the Spoke cluster

  spoke_cluster_url=$(oc whoami --show-console)

  set -x
  ${_curl} -vkI -u kubeadmin:${secret_adm_pass} ${spoke_cluster_url} || echo "Warning... the console is not present"
  set +x

  test_spoke_cluster_repo

  echo
  echo "Success!!! spoke_cluster has been deployed correctly."
}

function main {
  set_spoke_cluster_kubeconfig
  test_spoke_deployment
}

main
