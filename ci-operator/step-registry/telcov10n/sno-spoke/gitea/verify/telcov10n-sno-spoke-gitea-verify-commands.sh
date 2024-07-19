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

function test_gitea_deployment {

  echo "************ telcov10n Check Gitea service ************"

  gitea_project="ztp-gitea"
  gitea_ssh_host=$(oc get node openshift-master-0.lab.eng.rdu2.redhat.com -ojsonpath='{.status.addresses[?(.type=="InternalIP")].address}')
  gitea_ssh_nodeport=$(oc -n ${gitea_project} get service gitea-ssh -ojsonpath='{.spec.ports[?(.name=="ssh")].nodePort}')
  gitea_url=$(cat ${SHARED_DIR}/gitea-url.txt)

  set -x
  helm list --all-namespaces | grep "${gitea_project}"
  curl -vkI ${gitea_url}
  nc -vz ${gitea_ssh_host} ${gitea_ssh_nodeport}
  oc -n ${gitea_project} get all
  set +x

  clone_and_test_gitea_repo

  echo
  echo "Success!!! Gitea has been deployed correctly."
}

function clone_and_test_gitea_repo {
  echo "************ telcov10n clone Gitea repo ************"

  gitea_ssh_uri="$(cat ${SHARED_DIR}/gitea_ssh_uri.txt)"
  ssh_pri_key_file=${SHARED_DIR}/ssh-key-ztp-gitea

  ztp_repo_dir=$(mktemp -d)
  set -x
  GIT_SSH_COMMAND="ssh -v -o StrictHostKeyChecking=no -i ${ssh_pri_key_file}" git clone ${gitea_ssh_uri} ${ztp_repo_dir}

  test -f ${ztp_repo_dir}/README.md
  grep -w "$(cat ${ssh_pri_key_file}.pub)" ${ztp_repo_dir}/README.md

  set +x
}

function main {
  set_hub_cluster_kubeconfig
  test_gitea_deployment
}

main
