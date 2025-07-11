#!/bin/bash
set -e
set -o pipefail
# MOUNTED_HOST_INVENTORY="/var/host_variables"

process_inventory() {
    local directory="$1"
    local dest_file="$2"

    if [ -z "$directory" ]; then
        echo "Usage: process_inventory <directory> <dest_file>"
        return 1
    fi

    if [ ! -d "$directory" ]; then
        echo "Error: '$directory' is not a valid directory"
        return 1
    fi

    find "$directory" -type f | while IFS= read -r filename; do
        if [[ $filename == *"secretsync-vault-source-path"* ]]; then
          continue
        else
          echo "$(basename "${filename}")": \'"$(cat "$filename")"\'
        fi
    done > "${dest_file}"

    echo "Processing complete. Check \"${dest_file}\""
}

main() {

    echo "Set CLUSTER_NAME env var"
    if [[ -f "${SHARED_DIR}/cluster_name" ]]; then
        CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster_name")
    fi
    export CLUSTER_NAME=${CLUSTER_NAME}
    echo CLUSTER_NAME="${CLUSTER_NAME}"

    echo "Create group_vars directory"
    mkdir -p /eco-ci-cd/inventories/ocp-deployment/group_vars

    find /var/group_variables/common/ -mindepth 1 -type d | while read -r dir; do
        echo "Process group inventory file: ${dir}"
        process_inventory "$dir" /eco-ci-cd/inventories/ocp-deployment/group_vars/"$(basename "${dir}")"
    done

    echo "Create host_vars directory"
    mkdir -p /eco-ci-cd/inventories/ocp-deployment/host_vars

    echo "Load network mutation env variablies if present"
    if [[ -f "${SHARED_DIR}/set_ocp_net_vars.sh" ]]; then
        # shellcheck source=/dev/null
        source "${SHARED_DIR}/set_ocp_net_vars.sh"
    fi

    cd /eco-ci-cd
    echo "Deploy OCP for compute-nto testing"
    set -x
    no_run_it_ansible ./playbooks/deploy-ocp-hybrid-multinode.yml -i ./inventories/ocp-deployment/build-inventory.py \
        --extra-vars "release=${VERSION} cluster_name=${CLUSTER_NAME} kubeconfig=/home/telcov10n/project/generated/${CLUSTER_NAME}/auth/kubeconfig"
    set +x

    echo "Store inventory in SHARED_DIR"
    cp -r /eco-ci-cd/inventories/ocp-deployment/host_vars/* "${SHARED_DIR}"/
    cp -r /eco-ci-cd/inventories/ocp-deployment/group_vars/* "${SHARED_DIR}"/
}

pr_debug_mode_waiting() {

#   ext_code=$? ; [ $ext_code -eq 0 ] && return

  set -x
  echo "Store inventory in SHARED_DIR"
  cp -r /eco-ci-cd/inventories/ocp-deployment/host_vars/* "${SHARED_DIR}"/ || true
  cp -r /eco-ci-cd/inventories/ocp-deployment/group_vars/* "${SHARED_DIR}"/ || true

  [ -z "${PULL_NUMBER:-}" ] && return
  set +x

  echo "################################################################################"
  echo "# Using pull request ${PULL_NUMBER}. Entering in the debug mode waiting..."
  echo "################################################################################"

  TZ=UTC
  END_TIME=$(date -d "${DEBUGGING_TIMEOUT}" +%s)
  debug_done=/tmp/debug.done

  while sleep 1m; do

    test -f ${debug_done} && break
    echo
    echo "-------------------------------------------------------------------"
    echo "'${debug_done}' not found. Debugging can continue... "
    now=$(date +%s)
    if [ ${END_TIME} -lt ${now} ] ; then
      echo "Time out reached. Exiting by timeout..."
      break
    else
      echo "Now:     $(date -d @${now})"
      echo "Timeout: $(date -d @${END_TIME})"
    fi
    echo "Note: To exit from debug mode before the timeout is reached,"
    echo "just run the following command from the POD Terminal:"
    echo "$ touch ${debug_done}"

  done

  echo
  echo "Exiting from Pull Request debug mode..."
}

trap pr_debug_mode_waiting EXIT
main