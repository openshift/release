#!/bin/bash
set -e
set -o pipefail

echo "Checking if the job should be skipped..."
if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt file — skipping the job"
  exit 0
fi

ECO_CI_CD_INVENTORY_PATH="/eco-ci-cd/inventories/cnf"
HUB_KUBECONFIG="/home/telcov10n/project/generated/kni-qe-99/auth/kubeconfig"

# Process inventory from vault mounts
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
        # Check if content has newlines - if so, use literal block scalar (|)
        if [[ "$content" == *$'\n'* ]]; then
          echo "${varname}: |"
          echo "$content" | sed 's/^/  /'
        else
          echo "${varname}": \'"${content}"\'
        fi
    done > "${dest_file}"

    echo "Processing complete. Check \"${dest_file}\""
}

echo "SPOKE_CLUSTER=${SPOKE_CLUSTER}"

echo "Create group_vars directory"
mkdir -p "${ECO_CI_CD_INVENTORY_PATH}/group_vars"

echo "Process group inventory files from vault mounts"
find /var/group_variables/common/ -mindepth 1 -type d 2>/dev/null | while read -r dir; do
    echo "Process group inventory file: ${dir}"
    process_inventory "$dir" "${ECO_CI_CD_INVENTORY_PATH}/group_vars/$(basename "${dir}")"
done

echo "Create host_vars directory"
mkdir -p "${ECO_CI_CD_INVENTORY_PATH}/host_vars"

echo "Process host inventory files from vault mounts"
find /var/host_variables/kni-qe-99/ -mindepth 1 -type d 2>/dev/null | while read -r dir; do
    echo "Process host inventory file: ${dir}"
    process_inventory "$dir" "${ECO_CI_CD_INVENTORY_PATH}/host_vars/$(basename "${dir}")"
done

echo "Remove old report directories"
rm -rf /tmp/reports /tmp/junit

echo "Create reports directory"
mkdir -p /tmp/reports

echo "Copy polarion reports from SHARED_DIR (files with polarion_ prefix)"
for f in "${SHARED_DIR}"/polarion_*.xml; do
  if [[ -f "$f" ]]; then
    filename=$(basename "$f" | sed 's/^polarion_//')
    echo "Copying polarion report: $(basename "$f") -> ${filename}"
    cp "$f" "/tmp/reports/${filename}"
  fi
done

echo "Create junit directory"
mkdir -p /tmp/junit

echo "Copy junit reports from SHARED_DIR (files with junit_ prefix)"
for f in "${SHARED_DIR}"/junit_*.xml; do
  if [[ -f "$f" ]]; then
    filename=$(basename "$f" | sed 's/^junit_//')
    echo "Copying junit report: $(basename "$f") -> ${filename}"
    cp "$f" "/tmp/junit/${filename}"
  fi
done

cd /eco-ci-cd

echo "Upload reports to Polarion and Report Portal"
ansible-playbook ./playbooks/cnf/upload-report.yaml \
  -i ./inventories/cnf/switch-config.yaml \
  --extra-vars "kubeconfig=${HUB_KUBECONFIG} reporter_template_name='${REPORTER_TEMPLATE_NAME}' processed_report_dir=/tmp/reports junit_report_dir=/tmp/junit reports_directory=/tmp/upload upload_to_report_portal=${UPLOAD_TO_REPORT_PORTAL} report_portal_url_filename='.reportportal_url_standard'"
