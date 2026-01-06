#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ telcov10n Fix user IDs in a container ************"
[ -e "${HOME}/fix_uid.sh" ] && "${HOME}/fix_uid.sh" || echo "${HOME}/fix_uid.sh was not found" >&2

source ${SHARED_DIR}/common-telcov10n-bash-functions.sh

function set_hub_cluster_kubeconfig {
  echo "************ telcov10n Get Hub kubeconfig from \${SHARED_DIR}/hub-kubeconfig location ************"
  export KUBECONFIG="${SHARED_DIR}/hub-kubeconfig"
}

function setup_hub_cluster_with_argocd {

  echo "************ telcov10n Setup the Hub cluster with ArgoCD ************"

  echo "Copy ArgoCD deployment templates"
  argocd_templates_dir=$(mktemp -d)
  set -x
  cp -av ${HOME}/ztp/argocd/deployment/* ${argocd_templates_dir}
  set +x

  echo "Patch the ArgoCD instance to enable the PolicyGenerator plugin:"
  set -x
  oc patch argocd openshift-gitops -n openshift-gitops --type=merge \
    --patch-file ${HOME}/ztp/argocd/deployment/argocd-openshift-gitops-patch.json
  set +x

  echo "In RHACM 2.7 and later, the multicluster engine enables the cluster-proxy-addon feature by default."
  echo "Apply the following patch to disable the cluster-proxy-addon feature and remove the relevant hub cluster"
  echo "and managed pods that are responsible for this add-on."
  set -x
  oc patch mce multiclusterengine --type=merge --patch-file ${HOME}/ztp/argocd/deployment/disable-cluster-proxy-addon.json
  set +x

  echo "Setup ArgoCD deployment templates"
  git_source_repo_url="$(cat ${SHARED_DIR}/gitea-http-repo-uri.txt)"
  git_source_targetRevision=main
  set -x
  cd ${argocd_templates_dir}
  git_source_path=clusters
  sed -i.bak -r -e "s@path:.*@path: ${git_source_path}@" -e "s@repoURL:.*@repoURL: ${git_source_repo_url}@" -e "s@targetRevision:.*@targetRevision: ${git_source_targetRevision}@" *.yaml
  git_source_path=site-policies
  sed -i.bak -r -e "s@path:.*@path: ${git_source_path}@" *polic*yaml
  set +x

  echo "Apply the pipeline configuration to your hub cluster by using the following command:"
  set -x
  oc apply -k .
  set +x

  echo "Enabling ClusterImageSet CR to be managed by GitOps apps"
  app_patch_file="$(mktemp -d)/appproject-ztp-app-project.json"
  cat << EOF > ${app_patch_file}
{
  "spec": {
      "clusterResourceWhitelist": [
        {
          "group": "cluster.open-cluster-management.io",
          "kind": "ManagedCluster"
        },
        {
          "group": "",
          "kind": "Namespace"
        },
        {
          "group": "hive.openshift.io",
          "kind": "ClusterImageSet"
        }
    ]
  }
}
EOF

  set -x
  oc -n openshift-gitops patch appproject ztp-app-project --type merge --patch-file ${app_patch_file}
  set +x
}

function setup_hub_cluster_with_site_config_addon {

  echo "************ telcov10n Setup the Hub cluster with SiteConfig V2 addon ************"

  set -x
  is_addon_enable=$(oc -n ${MCH_NAMESPACE} get mch multiclusterhub -ojson | jq '
    .spec.overrides.components[] | select(.name == "siteconfig") | .enabled')
  set +x

  if [ "${is_addon_enable}" == "false" ]; then
    echo
    echo "Enabling SiteConfig V2 addon..."
    echo
    set -x
    oc -n ${MCH_NAMESPACE} patch multiclusterhubs.operator.open-cluster-management.io multiclusterhub \
      --type json \
      --patch '[{"op": "add", "path":"/spec/overrides/components/-", "value": {"name":"siteconfig","enabled": true}}]'
    set +x
    wait_until_command_is_ok "oc -n ${MCH_NAMESPACE} get po | grep siteconfig" 10s 30

    echo
    echo "Check SiteConfig templates..."
    echo
    set -x
    wait_until_command_is_ok "oc -n ${MCH_NAMESPACE} get cm | grep 'templates' | wc -l | grep -w '6'" 10s 30
    set +x
  else
    echo
    echo "SiteConfig V2 addon is already enabled."
    echo
  fi
  set -x
  oc -n ${MCH_NAMESPACE} get mch multiclusterhub -ojson | jq '.spec.overrides.components[] | select(.name == "siteconfig")'
  oc -n ${MCH_NAMESPACE} get cm | grep 'templates'
  oc -n ${MCH_NAMESPACE} get po | grep 'siteconfig'
  set +x
  echo
}

function configute_argocd_for_cluster_instance {

  echo "************ telcov10n Configure ArgoCD to cope with Cluster Instance CRs ************"

  cat << EOF | oc apply -f -
---
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: siteconfig-v2
  namespace: openshift-gitops
spec:
  clusterResourceWhitelist:
    - group: ""
      kind: Namespace
  namespaceResourceWhitelist:
    - group: ""
      kind: ConfigMap
    - group: ""
      kind: Secret
    - group: siteconfig.open-cluster-management.io
      kind: ClusterInstance
  sourceRepos:
    - '*'
  destinations:
    - namespace: '*'
      server: '*'
EOF

  wait_until_command_is_ok "oc -n openshift-gitops get AppProject | grep -w 'siteconfig-v2'" 1s 20
  set -x
  oc -n openshift-gitops get AppProject siteconfig-v2 -oyaml
  set +x
  echo
}

function setup_argocd_policy_plugin {

  echo "************ telcov10n Setup ArgoCD PolicyGenerator Plugin ************"

  echo "Patch the ArgoCD instance to enable the PolicyGenerator plugin:"
  set -x
  oc -n openshift-gitops patch argocd openshift-gitops \
    --type=merge --patch-file ${HOME}/ztp/argocd/deployment/argocd-openshift-gitops-patch.json
  set +x
  echo
}

function setup_argocd_roles_permissions {

  echo "************ telcov10n Setup ArgoCD roles permissions ************"

  cat <<EOF | oc apply -f -
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: gitops-cluster
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: openshift-gitops-argocd-application-controller
  namespace: openshift-gitops
EOF

  wait_until_command_is_ok "oc get ClusterRoleBinding gitops-cluster" 1s 20
  set -x
  oc get ClusterRoleBinding gitops-cluster -oyaml
  set +x
  echo
  set -x
  oc -n openshift-gitops get ServiceAccount openshift-gitops-argocd-application-controller -oyaml
  set +x
  echo

}

function create_argo_application {

  echo "************ telcov10n Create ArgoCD Application ************"

  git_source_repo_url="$(cat ${SHARED_DIR}/gitea-http-repo-uri.txt)"
  git_source_targetRevision=main
  git_source_path_for_clusters=clusters

  cat <<EOF | oc apply -f -
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${git_source_path_for_clusters}
  namespace: openshift-gitops
spec:
  destination:
    namespace: clusters-sub
    server: https://kubernetes.default.svc
  project: siteconfig-v2
  source:
    path: ${git_source_path_for_clusters}
    repoURL: ${git_source_repo_url}
    targetRevision: ${git_source_targetRevision}
  syncPolicy:
    automated:
      selfHeal: true
EOF

  wait_until_command_is_ok "oc -n openshift-gitops get applications.argoproj.io | grep 'clusters .* Healthy'" 10s 100
  set -x
  oc -n openshift-gitops get applications.argoproj.io clusters -oyaml
  set +x
  echo

  echo
  echo "Setup ArgoCD PolicyGenerator application for site-policies..."
  echo

  echo "Copy ArgoCD deployment templates"
  argocd_templates_dir=$(mktemp -d)
  set -x
  cp -av ${HOME}/ztp/argocd/deployment/* ${argocd_templates_dir}
  set +x

  echo "Setup ArgoCD policy deployment templates"
  set -x
  cd ${argocd_templates_dir}
  git_source_path_for_policies=site-policies
  sed -i.bak -r \
    -e "s@path:.*@path: ${git_source_path_for_policies}@" \
    -e "s@repoURL:.*@repoURL: ${git_source_repo_url}@" \
    -e "s@targetRevision:.*@targetRevision: ${git_source_targetRevision}@" \
    *.yaml
  sed -i.bak -r -e '/- app-project.yaml/d' -e '/- clusters-app.yaml/d' kustomization.yaml
  set +x

  echo "Apply the policies application configuration to your hub cluster:"
  set -x
  oc apply -k .
  set +x
}

function main {
  set_hub_cluster_kubeconfig
  if [ "${SITE_CONFIG_VERSION}" == "v2" ]; then
    setup_hub_cluster_with_site_config_addon
    configute_argocd_for_cluster_instance
    setup_argocd_policy_plugin
    setup_argocd_roles_permissions
    create_argo_application
  else
    setup_hub_cluster_with_argocd
  fi
}

main
