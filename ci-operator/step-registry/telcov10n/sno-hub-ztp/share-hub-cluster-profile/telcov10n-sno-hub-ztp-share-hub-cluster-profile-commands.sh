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

function save_hub_cluster_profile_artifacts {

  echo "************ telcov10n Save those artifacts that will be used during Spoke deployments ************"

  hub_to_spoke_artifacts=(
    "$(readlink -f ${KUBEADMIN_PASSWORD_FILE})"
    "$(readlink -f ${CLUSTER_PROFILE_DIR}/pull-secret)"
    "$(readlink -f ${CLUSTER_PROFILE_DIR}/base_domain)"
  )

  local_cluster_profile_shared_folder=$(mktemp -d --dry-run)/${SHARED_HUB_CLUSTER_PROFILE}
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
    "${NAMESPACE}" "${SHARED_HUB_CLUSTER_PROFILE}" << 'EOF'
set -o nounset
set -o errexit
set -o pipefail

telco_qe_preserved_dir=/var/builds/telco-qe-preserved

# Create the directory if it does not exist
# (which is the case the first time this code runs)
mkdir -pv ${telco_qe_preserved_dir}

set -x
if [[ -e ${telco_qe_preserved_dir}/${2} && ! -h ${telco_qe_preserved_dir}/${2} ]]; then
  file ${telco_qe_preserved_dir}/${2}
  set +x
  echo "Unexpected wrong condition found!!! The ${telco_qe_preserved_dir}/${2} file already exists and is not a symbolic link."
  exit 1
else
  rm -fv ${telco_qe_preserved_dir}/${2}
  ln -s /var/builds/${1}/${2} ${telco_qe_preserved_dir}/${2}
  ls -l ${telco_qe_preserved_dir}/${2} | grep "/var/builds/${1}/${2}" || \
    {
      set +x ;
      echo "Wrong generated '${telco_qe_preserved_dir}/${2}' symbolic link detected" ;
      exit 1 ;
    }
fi
EOF

  set +x
  echo
}

function main {
  setup_aux_host_ssh_access
  save_hub_cluster_profile_artifacts
  create_symbolic_link_to_shared_hub_cluster_profile_artifacts_folder
}

main
