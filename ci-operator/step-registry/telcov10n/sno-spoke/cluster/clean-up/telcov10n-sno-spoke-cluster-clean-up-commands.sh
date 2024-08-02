#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ telcov10n Fix user IDs in a container ************"
[ -e "${HOME}/fix_uid.sh" ] && "${HOME}/fix_uid.sh" || echo "${HOME}/fix_uid.sh was not found" >&2

function set_hub_cluster_kubeconfig {
  echo "************ telcov10n Get Hub kubeconfig from \${SHARED_DIR}/hub-kubeconfig location ************"
  export KUBECONFIG="${SHARED_DIR}/hub-kubeconfig"
}

function clean_up {

  echo "************ telcov10n Clean up SNO Spoke cluster artefacts ************"

  # ai_dp_secret_name="${SPOKE_CLUSTER_NAME}-assisted-deployment-pull-secret"
  # bmc_login_secret_name="${SPOKE_CLUSTER_NAME}-bmc-secret"

  SPOKE_CLUSTER_NAME=${NAMESPACE}

  set -x
  # oc -n ${SPOKE_CLUSTER_NAME} delete secret ${ai_dp_secret_name} ${bmc_login_secret_name} || echo
  oc -n ${SPOKE_CLUSTER_NAME} delete agentclusterinstalls.extensions.hive.openshift.io ${SPOKE_CLUSTER_NAME} || echo
  # TODO: Review this...
  # oc -n ${SPOKE_CLUSTER_NAME} delete bmh master-00.${SPOKE_CLUSTER_NAME}.lab.eng.rdu2.redhat.com
  set +x
}

function main {
  set_hub_cluster_kubeconfig
  clean_up

  echo
  echo "Success!!! The SNO Spoke cluster related objects have been removed correctly."
}

main
