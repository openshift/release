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

function get_hub_cluster_profile_artifacts {

  echo "************ telcov10n Get Hub cluster artifacts from AUX_HOST ************"

  echo
  set -x
  rsync -avP \
    -e "ssh $(echo "${SSHOPTS[@]}")" \
    "root@${AUX_HOST}":/var/builds/telco-qe-preserved/${SHARED_HUB_CLUSTER_PROFILE}/ \
    ${HOME}/${SHARED_HUB_CLUSTER_PROFILE}
  set +x
  echo
}

function set_hub_cluster_kubeconfig {

  echo "************ telcov10n Set Hub cluster kubeconfig got from shared profile ************"

  hub_kubeconfig="${HOME}/${SHARED_HUB_CLUSTER_PROFILE}/hub-kubeconfig"
  oc_hub="oc --kubeconfig ${hub_kubeconfig}"
}

function test_hub_cluster_deployment {

  set -x
  diff -u ${KUBECONFIG} ${hub_kubeconfig} || \
    ( echo "Wrong KUBECONFIG file retreived!!! Exiting..." && exit 1 )
  $oc_hub get no,clusterversion,mcp,co,sc,pv
  $oc_hub get subscriptions.operators,OperatorGroup,pvc -A
  $oc_hub whoami --show-console
  $oc_hub get managedcluster
  set +x

  echo "Current namespace is ${NAMESPACE}"
  base_domain=$(cat ${HOME}/${SHARED_HUB_CLUSTER_PROFILE}/base_domain)
  echo "Current base_domain is ${base_domain}"

  echo "Exiting successfully..."
}

function main {
  setup_aux_host_ssh_access
  get_hub_cluster_profile_artifacts
  set_hub_cluster_kubeconfig
  test_hub_cluster_deployment
}

main
