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

function setup_hub_cluster_with_argocd {

  echo "************ telcov10n Setup the Hub cluster with ArgoCD ************"

  echo "Copy ArgoCD deployment templates"
  argocd_templates_dir=$(mktemp -d)
  set -x
  cp -av ${HOME}/ztp/argocd/deployment/* ${argocd_templates_dir}
  set +x

  echo "Patch the ArgoCD instance in the hub cluster using the ${HOME}/ztp/argocd/deployment/argocd-openshift-gitops-patch.json patch file:"

#   argocd_gitops_patch=$(mktemp --dry-run)
#   cat <<EOF > ${argocd_gitops_patch}
# {
#   "spec": {
#     "repo": {
#       "initContainers": [
#         {
#           "args": [
#             "-c",
#             "mkdir -p /.config/kustomize/plugin/policy.open-cluster-management.io/v1/policygenerator && cp /policy-generator/PolicyGenerator-not-fips-compliant /.config/kustomize/plugin/policy.open-cluster-management.io/v1/policygenerator/PolicyGenerator"
#           ],
#           "command": [
#             "/bin/bash"
#           ],
#           "image": "${MULTICLUSTER_HUB_OPERATOR_SUBS}",
#           "name": "policy-generator-install",
#           "imagePullPolicy": "Always",
#           "volumeMounts": [
#             {
#               "mountPath": "/.config",
#               "name": "kustomize"
#             }
#           ]
#         }
#       ]
#     }
#   }
# }
# EOF

  set -x
  # jq -s '.[0] * .[1]' \
  #   ${HOME}/ztp/argocd/deployment/argocd-openshift-gitops-patch.json \
  #   ${argocd_gitops_patch} \
  #   > ${argocd_templates_dir}/argocd-openshift-gitops-patch.json
  # oc patch argocd openshift-gitops -n openshift-gitops --type=merge \
  #   --patch-file ${argocd_templates_dir}/argocd-openshift-gitops-patch.json
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
  git_source_path=site-configs
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

function main {
  set_hub_cluster_kubeconfig
  setup_hub_cluster_with_argocd
}

main