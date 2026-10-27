#!/bin/bash
set -e
set -o pipefail

echo "Checking if the job should be skipped..."
if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt file — skipping the job"
  exit 0
fi

ECO_CI_CD_INVENTORY_PATH="/eco-ci-cd/inventories/cnf"

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
        fi
        local content
        content=$(cat "$filename")
        local varname
        varname=$(basename "${filename}")
        if [[ "$content" == *$'\n'* ]]; then
          echo "${varname}: |"
          echo "$content" | sed 's/^/  /'
        else
          echo "${varname}: '${content//\'/\'\'}'"
        fi
    done > "${dest_file}"

    echo "Processing complete. Check \"${dest_file}\""
}


echo "Create group_vars directory"
mkdir -p "${ECO_CI_CD_INVENTORY_PATH}/group_vars"

echo "Process all common group variables"
while read -r dir; do
    echo "Process group inventory file: ${dir}"
    process_inventory "$dir" "${ECO_CI_CD_INVENTORY_PATH}/group_vars/$(basename "${dir}")"
done < <(find /var/group_variables/common/ -mindepth 1 -maxdepth 1 -type d ! -name '..*' 2>/dev/null)

echo "Process spoke cluster group variables"
while read -r dir; do
    echo "Process group inventory file: ${dir}"
    process_inventory "$dir" "${ECO_CI_CD_INVENTORY_PATH}/group_vars/$(basename "${dir}")"
done < <(find "/var/group_variables/${SPOKE_CLUSTER}/" -mindepth 1 -maxdepth 1 -type d ! -name '..*' 2>/dev/null)

echo "Create host_vars directory"
mkdir -p "${ECO_CI_CD_INVENTORY_PATH}/host_vars"

echo "Process bastion host variables (from hub ${HUB_CLUSTER})"
while read -r dir; do
    echo "Process host inventory file: ${dir}"
    process_inventory "$dir" "${ECO_CI_CD_INVENTORY_PATH}/host_vars/$(basename "${dir}")"
done < <(find "/var/host_variables/${HUB_CLUSTER}/" -mindepth 1 -maxdepth 1 -type d ! -name '..*' 2>/dev/null)

echo "Process spoke cluster host variables"
while read -r dir; do
    echo "Process host inventory file: ${dir}"
    process_inventory "$dir" "${ECO_CI_CD_INVENTORY_PATH}/host_vars/$(basename "${dir}")"
done < <(find "/var/host_variables/${SPOKE_CLUSTER}/" -mindepth 1 -maxdepth 1 -type d ! -name '..*' 2>/dev/null)

echo "Copying inventory to SHARED_DIR"
cp -r /eco-ci-cd/inventories/ocp-deployment/host_vars/* "${SHARED_DIR}"/
cp -r /eco-ci-cd/inventories/ocp-deployment/group_vars/* "${SHARED_DIR}"/