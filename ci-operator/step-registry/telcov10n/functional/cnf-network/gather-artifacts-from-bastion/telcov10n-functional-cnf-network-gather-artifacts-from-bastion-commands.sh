#!/bin/bash
set -e
set -o pipefail

PROJECT_DIR=/tmp

echo "Set CLUSTER_NAME env var"
if [[ -f "${SHARED_DIR}/cluster_name" ]]; then
    CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster_name")
fi
export CLUSTER_NAME=${CLUSTER_NAME}
echo CLUSTER_NAME="${CLUSTER_NAME}"

ALL_VARS="/var/common_variables/all"
BASTION_VARS="/var/clusters/${CLUSTER_NAME}/bastion"

if [[ ! -f "${BASTION_VARS}" ]]; then
  echo "Error: no bastion vars found at ${BASTION_VARS}" >&2
  exit 1
fi

echo "Set bastion ssh configuration"
# The private key spans several lines in ansible_group_all, take everything between the quotes
install -m 600 /dev/null "${PROJECT_DIR}/temp_ssh_key"
sed -n "/^ansible_ssh_private_key: /,/'\$/p" "${ALL_VARS}" \
  | sed -e "s/^ansible_ssh_private_key: '//" -e "s/'\$//" > "${PROJECT_DIR}/temp_ssh_key"

BASTION_IP=$(grep -oP '(?<=ansible_host: ).*' "${BASTION_VARS}" | sed "s/'//g")
BASTION_USER=$(grep -oP '(?<=ansible_user: ).*' "${ALL_VARS}" | sed "s/'//g")

echo "Create artifacts directory"
mkdir "${PROJECT_DIR}"/artifacts

echo "Store content from phase 1 run in SHARED_DIR"
scp -r -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "${PROJECT_DIR}/temp_ssh_key" "${BASTION_USER}@${BASTION_IP}":~/build-artifiacts/* "${PROJECT_DIR}"/artifacts/

echo "Gather inventory files"
for file in "${PROJECT_DIR}"/artifacts/*; do
  [[ "$file" == *.xml ]] && continue
  cp "${file}" "${SHARED_DIR}"/
done

echo "Copy reports for reporter step"
cp "${PROJECT_DIR}"/artifacts/report_*.xml "${SHARED_DIR}"/
cp "${PROJECT_DIR}"/artifacts/junit_*.xml "${SHARED_DIR}"/

mkdir "${ARTIFACT_DIR}/junit"
for file in "${PROJECT_DIR}"/artifacts/*.xml; do
  [[ $(basename "$file") == "report_polarion.xml" ]] && continue
  echo "${file}"
  cp "${file}" "${ARTIFACT_DIR}"/junit/
done
