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

function remove_related_git_info {

  SPOKE_CLUSTER_NAME=${NAMESPACE}

  echo "************ telcov10n Removing related Git into for the ${SPOKE_CLUSTER_NAME} spoke cluster ************"

  gitea_ssh_uri="$(cat ${SHARED_DIR}/gitea-ssh-uri.txt)"
  ssh_pri_key_file=${SHARED_DIR}/ssh-key-${GITEA_NAMESPACE}

  run_script=$(mktemp --dry-run)

  cat <<EOF > ${run_script}
set -o nounset
set -o errexit
set -o pipefail

echo "$(cat ${ssh_pri_key_file})" > /tmp/ssh-prikey
chmod 0400 /tmp/ssh-prikey

set -x
ztp_repo_dir=\$(mktemp -d --dry-run)
git config --global user.email "ztp-spoke-cluster@telcov10n.com"
git config --global user.name "ZTP Spoke Cluster Telco Verification"
GIT_SSH_COMMAND="ssh -v -o StrictHostKeyChecking=no -i /tmp/ssh-prikey" git clone ${gitea_ssh_uri} \${ztp_repo_dir}

if [ -f \${ztp_repo_dir}/clusters/kustomization.yaml ]; then
  sed -i '/${SPOKE_CLUSTER_NAME}/d' \${ztp_repo_dir}/clusters/kustomization.yaml
fi

if [ -f \${ztp_repo_dir}/site-policies/kustomization.yaml ]; then
  sed -i '/${SPOKE_CLUSTER_NAME}/d' \${ztp_repo_dir}/site-policies/kustomization.yaml
fi

cd \${ztp_repo_dir}
# The below line is to force the commit always push something
# even when you run this twice for exactly the same cluster
touch .${SPOKE_CLUSTER_NAME}-deleted-at-$(date -u +%s%N)
git add .
git rm -r clusters/${SPOKE_CLUSTER_NAME}
[ -d site-policies/${SPOKE_CLUSTER_NAME} ] && git rm -r site-policies/${SPOKE_CLUSTER_NAME}
git commit -m 'Delete Related ${SPOKE_CLUSTER_NAME} spoke cluster GitOps files'
GIT_SSH_COMMAND="ssh -v -o StrictHostKeyChecking=no -i /tmp/ssh-prikey" git push origin main || {
GIT_SSH_COMMAND="ssh -v -o StrictHostKeyChecking=no -i /tmp/ssh-prikey" git pull -r origin main &&
GIT_SSH_COMMAND="ssh -v -o StrictHostKeyChecking=no -i /tmp/ssh-prikey" git push origin main ; }
EOF

  gitea_project="${GITEA_NAMESPACE}"
  run_script_on_ocp_cluster ${run_script} ${gitea_project}
}

function clean_up {

  echo "************ telcov10n Clean up Gitops apps ************"
  # set -x
  # oc -n openshift-gitops delete apps clusters policies || echo "Gitops k8s apps didn't exist..."
  # set +x

  remove_related_git_info
}

function main {
  set_hub_cluster_kubeconfig
  clean_up

  echo
  echo "Success!!! The Gitops related info for the ${SPOKE_CLUSTER_NAME} spoke cluster have been removed correctly."
}

main
