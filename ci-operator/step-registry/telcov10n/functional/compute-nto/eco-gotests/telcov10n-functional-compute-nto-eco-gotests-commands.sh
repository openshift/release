#!/bin/bash
set -e
set -o pipefail

ECO_CI_CD_INVENTORY_PATH="/eco-ci-cd/inventories/ocp-deployment"
REPORT_DIR=/tmp/artifacts/
PROJECT_DIR="/tmp"

# backwards compatibility for process inventory step
if [[ -f "${SHARED_DIR}/process-inventory-completed" ]]; then
  echo "Copy inventory files"
  mkdir -pv ${ECO_CI_CD_INVENTORY_PATH}/group_vars
  mkdir -pv ${ECO_CI_CD_INVENTORY_PATH}/host_vars

  for file in ${SHARED_DIR}/*; do 
      if [[ "$file" == *"group_vars_"* || "$file" == *"host_vars_"* ]]; then
          DEST_DIR=$( basename $file | cut -d'_' -f1,2 )
          DEST_FILE=$( basename $file | cut -d'_' -f3 )
          cp $file ${ECO_CI_CD_INVENTORY_PATH}/$DEST_DIR/$DEST_FILE
      fi
  done
else

  echo "Create group_vars directory"
  mkdir -p "${ECO_CI_CD_INVENTORY_PATH}/group_vars"

  echo "Copy group inventory files"
  # shellcheck disable=SC2154
  cp "${SHARED_DIR}/all" "${ECO_CI_CD_INVENTORY_PATH}/group_vars/all"
  cp "${SHARED_DIR}/bastions" "${ECO_CI_CD_INVENTORY_PATH}/group_vars/bastions"

  echo "Create host_vars directory"
  mkdir -p "${ECO_CI_CD_INVENTORY_PATH}/host_vars"

  echo "Copy host inventory files"
  cp "${SHARED_DIR}/bastion" "${ECO_CI_CD_INVENTORY_PATH}/host_vars/bastion"

fi


echo "Set CLUSTER_NAME env var"
if [[ -f "${SHARED_DIR}/cluster_name" ]]; then
    CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster_name")
fi
export CLUSTER_NAME=${CLUSTER_NAME}
echo "CLUSTER_NAME=${CLUSTER_NAME}"

echo "Load compute-nto specific environment variables"
if [[ -f "${SHARED_DIR}/set_ocp_net_vars.sh" ]]; then
    # shellcheck source=/dev/null
    source "${SHARED_DIR}/set_ocp_net_vars.sh"
fi

echo "Creating an artifact directory"
  mkdir -p "${ARTIFACT_DIR}/junit_eco_gotests/"

echo "Setup compute-nto test script"
cd /eco-ci-cd

# shellcheck disable=SC2154
set -x
ansible-playbook ./playbooks/compute/deploy-nto-gotest.yml -i ./inventories/ocp-deployment/build-inventory.py \
    --extra-vars cluster_name=${CLUSTER_NAME} \
    --extra-vars label_filter=${LABEL_FILTER} \
    --extra-vars artifacts_folder="${REPORT_DIR}" \
    --extra-vars kubeconfig=/home/telcov10n/project/generated/${CLUSTER_NAME}/auth/kubeconfig

echo "Run NTO gotests via SSH (playbook creates files on bastion, not locally)"

echo "Set bastion ssh configuration"
grep ansible_ssh_private_key -A 100 "${ECO_CI_CD_INVENTORY_PATH}/group_vars/all" | sed 's/ansible_ssh_private_key: //g' | sed "s/'//g" > "${PROJECT_DIR}/temp_ssh_key"

chmod 600 "${PROJECT_DIR}/temp_ssh_key"
BASTION_IP=$(grep -oP '(?<=ansible_host: ).*' "${ECO_CI_CD_INVENTORY_PATH}/host_vars/bastion" | sed "s/'//g")
BASTION_USER=$(grep -oP '(?<=ansible_user: ).*' "${ECO_CI_CD_INVENTORY_PATH}/group_vars/all" | sed "s/'//g")

echo "Run compute-nto eco-gotests via ssh tunnel"
# Temporarily disable set -e to capture SSH exit code
set +e
timeout -s 9 "${ECO_GOTESTS_SSH_TIMEOUT}" ssh \
  -o ServerAliveInterval=60 \
  -o ServerAliveCountMax=3 \
  -o StrictHostKeyChecking=no \
  "${BASTION_USER}@${BASTION_IP}" -i ${PROJECT_DIR}/temp_ssh_key bash -s -- << 'EOF'
set -o nounset
set -o errexit
set -o pipefail

echo
echo "--------------------------------------------------"
echo "Running gotests script: /tmp/gotest/run_gotests.sh"
echo "--------------------------------------------------"
cat /tmp/gotest/run_gotests.sh
echo "--------------------------------------------------"
echo
cd /tmp/gotest && ./run_gotests.sh || true
EOF
ssh_ret=$?
# Re-enable set -e for the rest of the script
set -e
set +x
if [[ $ssh_ret -ne 0 ]]; then
    echo
    echo "-------------------------------------------------------------"
    echo "[WARNING] The test script exited with $ssh_ret from ssh!!!!"
    echo "-------------------------------------------------------------"
    echo "The step will continue to run but the test results"
    echo "might not be available or might be incomplete."
    echo "-------------------------------------------------------------"
    echo
fi

scp -r -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ${PROJECT_DIR}/temp_ssh_key \
  "${BASTION_USER}@${BASTION_IP}":"${REPORT_DIR}/*.xml" "${ARTIFACT_DIR}/junit_eco_gotests/"

echo "Create junit-named copies in ARTIFACT_DIR for reporter compatibility"
for xml_file in "${ARTIFACT_DIR}"/junit_eco_gotests/*.xml; do
  echo "xml_file: ${xml_file}"
  if [[ -f "${xml_file}" ]]; then
    basename_file=$(basename "${xml_file}")
    # Prepend junit_ to any XML filename
    junit_name="junit_${basename_file}"
    cp -v "${xml_file}" "${ARTIFACT_DIR}/junit_eco_gotests/${junit_name}"
    echo "Created junit copy: ${basename_file} -> ${junit_name}"
  fi
done

ls -la "${ARTIFACT_DIR}"/junit_eco_gotests/*.xml

echo "Copy junit test reports to shared directory for reporter step"
cp -v "${ARTIFACT_DIR}"/junit_eco_gotests/*.xml "${SHARED_DIR}/" 2>/dev/null || echo "No junit test reports found to copy to SHARED_DIR"

touch "${SHARED_DIR}/gotest-completed"
