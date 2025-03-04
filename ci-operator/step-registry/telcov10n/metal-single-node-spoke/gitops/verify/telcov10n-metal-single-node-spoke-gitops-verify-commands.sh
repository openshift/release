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

function wait_until_command_is_ok {
  cmd=$1 ; shift
  [ $# -gt 0 ] && sleep_for=${1} && shift && \
  [ $# -gt 0 ] && max_attempts=${1}  && shift
  set -x
  for ((attempts = 0 ; attempts <  ${max_attempts:=10} ; attempts++)); do
    eval "${cmd}" && { set +x ; return ; }
    sleep ${sleep_for:='1m'}
  done
  exit 1
}

function wait_for_argocd_apps {

  echo "************ telcov10n Check Gitops service: Wait for ArgoCD to deploy all their apps components ************"

  wait_until_command_is_ok "oc -n openshift-gitops get apps clusters | grep -w 'Synced'" 10s 100 && \
  wait_until_command_is_ok "oc -n openshift-gitops get apps policies | grep -w 'Synced'" 10s 100 && \
  set -x
  oc -n openshift-gitops wait apps/clusters --for=jsonpath='{.status.health.status}'=Healthy --timeout 30m && \
  oc -n openshift-gitops wait apps/clusters --for=jsonpath='{.status.sync.status}'=Synced --timeout 30m && \
  oc -n openshift-gitops wait apps/policies --for=jsonpath='{.status.health.status}'=Healthy --timeout 30m && \
  oc -n openshift-gitops wait apps/policies --for=jsonpath='{.status.sync.status}'=Synced --timeout 30m
  set +x
}

function test_gitops_deployment {

  echo "************ telcov10n Check Gitops service ************"

  wait_for_argocd_apps
}

function main {
  set_hub_cluster_kubeconfig
  test_gitops_deployment

  echo
  echo "Success!!! GitOps has been deployed correctly."
}

main
