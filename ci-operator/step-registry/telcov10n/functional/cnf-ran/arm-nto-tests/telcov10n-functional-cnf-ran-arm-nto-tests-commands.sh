#!/bin/bash
set -e
set -o pipefail

INVENTORY_PATH="/eco-ci-cd/inventories/ocp-deployment"

# copy inventory to shared dir
mkdir ${INVENTORY_PATH}/group_vars
cp -r "${SHARED_DIR}"/all ${INVENTORY_PATH}/group_vars/

mkdir ${INVENTORY_PATH}/host_vars
cp -r "${SHARED_DIR}"/bastion ${INVENTORY_PATH}/host_vars/


echo "Setup SSH connection..."
echo "Set bastion SSH configuration"
cat  "${INVENTORY_PATH}/group_vars/all/ansible_ssh_private_key" > "${PROJECT_DIR}/temp_ssh_key"
chmod 600 "${PROJECT_DIR}/temp_ssh_key"
trap 'rm -f "${PROJECT_DIR}/temp_ssh_key"' EXIT


SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

BASTION_IP=$(grep -oP '(?<=ansible_host: ).*' "${INVENTORY_PATH}/host_vars/bastion" | sed "s/'//g")
BASTION_USER=$(grep -oP '(?<=ansible_user: ).*' "${INVENTORY_PATH}/group_vars/all" | sed "s/'//g")



# Quote local values for the remote Bash command. The quoted heredoc below
# leaves all variables and command substitutions in its body for the bastion.
printf -v REMOTE_COMMAND 'bash -se -- %q %q %q' \
  "${CLUSTER_NAME}" \
  "${SPOKE_CLUSTER_NAME}" \
  "${NTO_GIT_URL}"

ssh "${SSH_OPTS[@]}" \
  -i "${PROJECT_DIR}/temp_ssh_key" \
  "${BASTION_USER}@${BASTION_IP}" "${REMOTE_COMMAND}" <<'EOF'
set -o pipefail

CLUSTER_NAME="$1"
SPOKE_CLUSTER_NAME="$2"
NTO_GIT_URL="$3"
export KUBECONFIG="/home/telcov10n/project/generated/${CLUSTER_NAME}/auth/kubeconfig"

WORK_DIR=$(mktemp -d)
cd "${WORK_DIR}"

echo "Clone NTO repo"
if [ -d "cluster-node-tuning-operator" ]; then
  rm -rf cluster-node-tuning-operator 
fi

git clone "${NTO_GIT_URL}" cluster-node-tuning-operator
cd cluster-node-tuning-operator


SPOKE_KUBECONFIG_PATH=/home/telcov10n/project/generated/${CLUSTER_NAME}/auth/spoke-kubeconfig

# Auto-detects cluster name, decodes kubeconfig, and writes to kubeconfig-spoke
echo "Getting Spoke ${SPOKE_CLUSTER_NAME} kubeconfig"
oc extract secret/$(oc get clusterdeployment -n ${SPOKE_CLUSTER_NAME} -o jsonpath='{.items[0].metadata.name}')-admin-kubeconfig \
  -n ${SPOKE_CLUSTER_NAME} \
  --to=- \
  --keys=kubeconfig > "${SPOKE_KUBECONFIG_PATH}" && chmod 600 "${SPOKE_KUBECONFIG_PATH}"


echo "Creating Must Gather"
export MUSTGATHER_DIR=$(mktemp -d --suffix -must-gather)
oc adm must-gather --kubeconfig=${SPOKE_KUBECONFIG_PATH} --dest-dir=${MUSTGATHER_DIR}


export NTO_IMAGE=$(oc --kubeconfig ${SPOKE_KUBECONFIG_PATH} get clusterversion version -o jsonpath='{.status.desired.image}')
export IMAGE_REGISTRY="quay.io/redhat-user-workloads/telco-5g-tenant/"
export CNF_TESTS_IMAGE=cnf-tests-4-20:on-pr-2751
export PERF_TEST_PROFILE=openshift-node-performance-profile
export ROLE_WORKER_CNF=worker-du

export PATH="/home/telcov10n/go/bin:/usr/local/go/bin:$PATH"
export KUBECONFIG="${SPOKE_KUBECONFIG_PATH}"
export BUSY_CPUS_IMAGE="${CNF_TESTS_IMAGE}"
export TEST_FOLDER_PATH='test/e2e/performanceprofile/functests'


OUTPUT_DIR="/tmp/artifacts"
rm -rf "${OUTPUT_DIR}" && mkdir -p "${OUTPUT_DIR}"

echo "Installing ginkgo and gomega..."
go install github.com/onsi/ginkgo/v2/ginkgo@latest

go mod tidy && go mod vendor
make vet

echo "Running gotests..."
ginkgo -v -r --keep-separate-reports --keep-going --flake-attempts=2 --junit-report=_report.xml \
  --label-filter="tier-0 && !hypershift" \
  --timeout=24h \
  --output-dir="${OUTPUT_DIR}" \
  --require-suite "${TEST_FOLDER_PATH}/0_config" \
                  "${TEST_FOLDER_PATH}/1_performance" \
                  "${TEST_FOLDER_PATH}/2_performance_update" \
                  "${TEST_FOLDER_PATH}/3_performance_status" \
                  "${TEST_FOLDER_PATH}/6_mustgather_testing" \
                  "${TEST_FOLDER_PATH}/7_performance_kubelet_node" \
                  "${TEST_FOLDER_PATH}/8_performance_workloadhints" \
                  "${TEST_FOLDER_PATH}/10_performance_ppc"


echo "Generate HTML report"

script_url=https://raw.githubusercontent.com/openshift-kni/telco5gci/refs/heads/master/j2html.py
requirements_url=https://raw.githubusercontent.com/openshift-kni/telco5gci/refs/heads/master/requirements.txt

echo "Install dependencies"
pip install -r ${requirements_url}

echo "Download script"
curl -o /tmp/j2html.py ${script_url}

cd "${OUTPUT_DIR}"
python3 /tmp/j2html.py --format xml *.xml --output nto_test_report.html 2>/dev/null || echo "No JUnit files found to generate HTML report"
EOF


# copy artifacs to ArtifactsDir
scp -i "${PROJECT_DIR}/temp_ssh_key" -r "${BASTION_USER}@${BASTION_IP}:/tmp/artifacts" "${ARTIFACTS_DIR}"

