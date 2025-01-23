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

function run_tests {
  echo "************ telcov10n Verifying installation ************"

  oc get managedcluster || echo "No ready..."

  SPOKE_CLUSTER_NAME=${NAMESPACE}
  secret_kubeconfig=${SPOKE_CLUSTER_NAME}-admin-kubeconfig
  secret_adm_pass=${SPOKE_CLUSTER_NAME}-admin-password

  echo "username: kubeadmin" >| ${SHARED_DIR}/admin-pass-${SPOKE_CLUSTER_NAME}.yaml
  echo "password: $(cat ${SHARED_DIR}/spoke-${secret_adm_pass}.yaml)" \
    >> ${SHARED_DIR}/admin-pass-${SPOKE_CLUSTER_NAME}.yaml

  if [ -n "${PULL_NUMBER:-}" ]; then
    echo
    echo "------------------------ Spoke Details --------------------------------------------------------"
    echo "OCP Installed Version:"
    oc --kubeconfig ${SHARED_DIR}/spoke-${secret_kubeconfig}.yaml get clusterversions.config.openshift.io
    echo
    echo "kubeconfig: export KUBECONFIG=${SHARED_DIR}/spoke-${secret_kubeconfig}.yaml"
    echo "Console: $(oc --kubeconfig ${SHARED_DIR}/spoke-${secret_kubeconfig}.yaml whoami --show-console)"
    cat ${SHARED_DIR}/admin-pass-${SPOKE_CLUSTER_NAME}.yaml
  fi
}

function main {
  set_hub_cluster_kubeconfig
  run_tests

  echo
  echo "Success!!! The SNO Spoke cluster has been verified."
}

main
