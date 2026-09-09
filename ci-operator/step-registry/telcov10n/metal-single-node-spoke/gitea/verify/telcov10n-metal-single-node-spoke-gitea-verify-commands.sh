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

  if [ -n "${SOCKS5_PROXY}" ]; then
    _curl="curl -x ${SOCKS5_PROXY}"
  else
    _curl="curl"
  fi
}

function setup_socks5_proxy_via_aux_host {

  # The lab publishes the '*.apps' wildcard at the internal ingress VIP, which is only
  # routable from inside the lab network. AUX_HOST sits on that network and serves its
  # DNS zone, so tunnel through it and let the proxy resolve names remotely (socks5h).
  if [ -n "${SOCKS5_PROXY}" ]; then
    echo "************ telcov10n Using the SOCKS5 proxy given by the job config ************"
    return
  fi

  echo "************ telcov10n Open a SOCKS5 tunnel through AUX_HOST ************"

  ssh -f -N -D "127.0.0.1:${SOCKS5_LOCAL_PORT}" \
    -o ExitOnForwardFailure=yes \
    "${SSHOPTS[@]}" "root@${AUX_HOST}"

  for ((attempts = 0 ; attempts < 10 ; attempts++)); do
    if timeout 5 bash -c "> /dev/tcp/127.0.0.1/${SOCKS5_LOCAL_PORT}" 2>/dev/null; then
      export SOCKS5_PROXY="socks5h://127.0.0.1:${SOCKS5_LOCAL_PORT}"
      echo "SOCKS5 tunnel listening on 127.0.0.1:${SOCKS5_LOCAL_PORT}"
      return
    fi
    sleep 3
  done

  echo "[FAIL] The SOCKS5 tunnel through ${AUX_HOST} did not come up..."
  exit 1
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

  run_script_on_ocp_cluster ${run_script} ${gitea_project} "${NAMESPACE}-helper" "done"
}

function test_gitea_deployment {

  echo "************ telcov10n Check Gitea service ************"

  gitea_project="${GITEA_NAMESPACE}"
  gitea_url=$(cat ${SHARED_DIR}/gitea-url.txt)

  set -x
  helm list --all-namespaces | grep "${gitea_project}"
  ${_curl} -vkI ${gitea_url} || echo "Warning... maybe the proxy is no longer up and running"
  oc -n ${gitea_project} get all
  set +x

  clone_and_test_gitea_repo

  echo
  echo "Success!!! Gitea has been deployed correctly."
}

function main {
  setup_aux_host_ssh_access
  setup_socks5_proxy_via_aux_host
  set_hub_cluster_kubeconfig
  test_gitea_deployment
}

main
