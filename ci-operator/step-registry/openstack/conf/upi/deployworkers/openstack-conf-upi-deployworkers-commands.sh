#!/usr/bin/env bash
set -o nounset
set -o errexit
set -o pipefail

function deploy_compute_nodes() {
  ansible-playbook -i "${ASSETS_DIR}/inventory.yaml" "${ASSETS_DIR}/compute-nodes.yaml"
}

function wait_for_compute_nodes() {
    sleep 60
}


function approve_csrs() {
  while true; do
    if [[ ! -f ${TMP_SHARED}/setup-complete ]]; then
      oc get csr -o jsonpath='{.items[*].metadata.name}' | xargs --no-run-if-empty oc adm certificate approve
      sleep 15 & wait
      continue
    else
      break
    fi
  done
}

function approve_csrs_in_background() {
  echo "Approving pending CSRs"
  export KUBECONFIG=${ASSETS_DIR}/auth/kubeconfig
  approve_csrs &
}

deploy_compute_nodes
wait_for_compute_nodes
approve_csrs_in_background