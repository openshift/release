#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ Fix container user ************"
# Fix user IDs in a container
[ -e "${HOME}/fix_uid.sh" ] && "${HOME}/fix_uid.sh" || echo "${HOME}/fix_uid.sh was not found" >&2

function setup_aux_host_ssh_access {

  echo "************ telcov10n Setup AUX_HOST SSH access ************"

  SSHOPTS=(
    -o 'ConnectTimeout=5'
    -o 'StrictHostKeyChecking=no'
    -o 'UserKnownHostsFile=/dev/null'
    -o 'ServerAliveInterval=90'
    -o LogLevel=ERROR
    -i "${CLUSTER_PROFILE_DIR}/ssh-key"
  )

}

function append_pr_tag_cluster_profile_artifacts {

  telco_qe_preserved_dir=/var/builds/telco-qe-preserved

  # Just in case of running this script being part of a Pull Request
  if [ -n "${PULL_NUMBER:-}" ]; then
    echo "************ telcov10n Append the 'pr-${PULL_NUMBER}' tag to '${telco_qe_preserved_dir}' folder ************"
    # shellcheck disable=SC2153
    telco_qe_preserved_dir="${telco_qe_preserved_dir}-pr-${PULL_NUMBER}"
  fi
}

function save_hub_cluster_profile_artifacts {

  echo "************ telcov10n Save those artifacts that will be used during Spoke deployments ************"

  hub_to_spoke_artifacts=(
    "$(readlink -f ${KUBEADMIN_PASSWORD_FILE})"
    "$(readlink -f ${CLUSTER_PROFILE_DIR}/pull-secret)"
    "$(readlink -f ${CLUSTER_PROFILE_DIR}/base_domain)"
  )

  # shellcheck disable=SC2153
  local_cluster_profile_shared_folder="$(mktemp -d --dry-run)/${SHARED_HUB_CLUSTER_PROFILE}"
  mkdir -pv ${local_cluster_profile_shared_folder}
  cp -av "${hub_to_spoke_artifacts[@]}" ${local_cluster_profile_shared_folder}/
  cp -v  "$(readlink -f ${KUBECONFIG})" ${local_cluster_profile_shared_folder}/hub-kubeconfig

  echo
  set -x
  rsync -avP --delete-before \
    -e "ssh $(echo "${SSHOPTS[@]}")" \
    "${local_cluster_profile_shared_folder}" \
    "root@${AUX_HOST}":/var/builds/${NAMESPACE}
  set +x
  echo
}

function create_symbolic_link_to_shared_hub_cluster_profile_artifacts_folder {
  
  echo "************ telcov10n Create a symbolic link to the shared artifacts folder that would be used during Spoke deployments ************"

  echo
  set -x
  timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" bash -s --  \
    "${NAMESPACE}" "${telco_qe_preserved_dir}" << 'EOF'
set -o nounset
set -o errexit
set -o pipefail

telco_qe_preserved_dir=${2}

set -x
if [[ -e ${telco_qe_preserved_dir} && ! -h ${telco_qe_preserved_dir} ]]; then
  file ${telco_qe_preserved_dir}
  set +x
  echo "Unexpected wrong condition found!!! The ${telco_qe_preserved_dir} file already exists and is not a symbolic link."
  exit 1
else
  rm -fv ${telco_qe_preserved_dir}
  ln -s /var/builds/${1} ${telco_qe_preserved_dir}
  find ${telco_qe_preserved_dir}/ | grep "/hub-kubeconfig" || \
    {
      set +x ;
      echo "Wrong generated '${telco_qe_preserved_dir}' symbolic link detected" ;
      echo "Missing 'hub-kubeconfig' file" ;
      exit 1 ;
    }
fi
EOF

  set +x
  echo
}

function main {
  setup_aux_host_ssh_access
  append_pr_tag_cluster_profile_artifacts
  save_hub_cluster_profile_artifacts
  create_symbolic_link_to_shared_hub_cluster_profile_artifacts_folder
}

main
