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

function run_script_in_the_hub_cluster {
  local helper_img="${GITEA_HELPER_IMG}"
  local script_file=$1
  shift && local ns=$1
  [ $# -gt 1 ] && shift && local pod_name="${1}"

  set -x
  if [[ "${pod_name:="--rm hub-script"}" != "--rm hub-script" ]]; then
    oc -n ${ns} get pod ${pod_name} 2> /dev/null || {
      oc -n ${ns} run ${pod_name} \
        --image=${helper_img} --restart=Never -- sleep infinity ; \
      oc -n ${ns} wait --for=condition=Ready pod/${pod_name} --timeout=10m ;
    }
    oc -n ${ns} exec -i ${pod_name} -- \
      bash -s -- <<EOF
$(cat ${script_file})
EOF
  [ $# -gt 1 ] && oc -n ${ns} delete pod ${pod_name}
  else
    oc -n ${ns} run -i ${pod_name} \
      --image=${helper_img} --restart=Never -- \
        bash -s -- <<EOF
$(cat ${script_file})
EOF
  fi
  set +x
}

function clone_and_test_gitea_repo {

  echo "************ telcov10n Clone and verify Gitea repo ************"

  gitea_ssh_uri="$(cat ${SHARED_DIR}/gitea-ssh-uri.txt)"
  ssh_pri_key_file=${SHARED_DIR}/ssh-key-${GITEA_NAMESPACE}

  run_script=$(mktemp --dry-run)

  cat <<EOF > ${run_script}
set -o nounset
set -o errexit
set -o pipefail

set -x
ztp_repo_dir=\$(mktemp -d)
test -f /tmp/ssh-prikey
GIT_SSH_COMMAND="ssh -v -o StrictHostKeyChecking=no -i /tmp/ssh-prikey" git clone ${gitea_ssh_uri} \${ztp_repo_dir}
test -f \${ztp_repo_dir}/README.md
grep -w "$(cat ${ssh_pri_key_file}.pub)" \${ztp_repo_dir}/README.md
EOF

  run_script_in_the_hub_cluster ${run_script} ${gitea_project} "gitea-pod-helper" "done"
}

function test_gitea_deployment {

  echo "************ telcov10n Check Gitea service ************"

  gitea_project="${GITEA_NAMESPACE}"
  gitea_url=$(cat ${SHARED_DIR}/gitea-url.txt)

  set -x
  helm list --all-namespaces | grep "${gitea_project}"
  curl -vkI ${gitea_url} || echo "Warning... maybe the proxy is no longer up and running"
  oc -n ${gitea_project} get all
  set +x

  clone_and_test_gitea_repo

  echo
  echo "Success!!! Gitea has been deployed correctly."
}

function main {
  set_hub_cluster_kubeconfig
  test_gitea_deployment
}

main
