#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ telcov10n Fix user IDs in a container ************"
[ -e "${HOME}/fix_uid.sh" ] && "${HOME}/fix_uid.sh" || echo "${HOME}/fix_uid.sh was not found" >&2

source ${SHARED_DIR}/common-telcov10n-bash-functions.sh

function set_hub_cluster_kubeconfig {
  echo "************ telcov10n Set Hub kubeconfig from  \${SHARED_DIR}/hub-kubeconfig location ************"
  export KUBECONFIG="${SHARED_DIR}/hub-kubeconfig"
}

function wait_for_argocd_apps {

  echo "************ telcov10n Check Gitops service: Wait for ArgoCD to deploy all their apps components ************"

  wait_until_command_is_ok "oc -n openshift-gitops get apps clusters | grep -w 'Synced'" 10s 50 && \
  wait_until_command_is_ok "oc -n openshift-gitops get apps policies | grep -w 'Synced'" 10s 50 && \
  set -x && \
  oc -n openshift-gitops wait apps/clusters --for=jsonpath='{.status.sync.status}'=Synced --timeout 30m && \
  oc -n openshift-gitops wait apps/clusters --for=jsonpath='{.status.health.status}'=Healthy --timeout 30m && \
  oc -n openshift-gitops wait apps/policies --for=jsonpath='{.status.sync.status}'=Synced --timeout 30m && \
  set +x
}

function wait_for_managedcluster {

  echo "************ telcov10n Check Gitops service: Wait until managedcluster object is created ************"

  SPOKE_CLUSTER_NAME=${NAMESPACE}

  wait_until_command_is_ok "oc get managedcluster | grep -w '${SPOKE_CLUSTER_NAME}'" 10s 100 && \
  wait_until_command_is_ok "oc get ns | grep -w '${SPOKE_CLUSTER_NAME}'" 10s 100
}

function try_to_recover_argocd_clusters_app {

  echo "Cleaning and restoring ArgoCD apps..."

  argo_clusters_app=$(mktemp --suffix=.json)
  set -x
  oc -n openshift-gitops get apps clusters -ojson | jq -r '
  {
    "apiVersion": .apiVersion,
    "kind": .kind,
    "metadata": {
        "name": .metadata.name,
        "namespace": .metadata.namespace
    },
    "spec": .spec
  }' > ${argo_clusters_app}
  oc replace -f ${argo_clusters_app}
  set +x

}

function test_gitops_deployment {

  echo "************ telcov10n Check Gitops service ************"

  wait_for_argocd_apps || {
    try_to_recover_argocd_clusters_app ;
    wait_for_argocd_apps ;
  }
  wait_for_managedcluster
}

function main {
  set_hub_cluster_kubeconfig
  test_gitops_deployment

  echo
  echo "Success!!! GitOps has been deployed correctly."
}

main
