#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release

oc config view
oc projects
python --version
pushd /tmp
python -m virtualenv ./venv_qe
source ./venv_qe/bin/activate

ES_PASSWORD=$(cat "/secret/password")
ES_USERNAME=$(cat "/secret/username")

REPO_URL="https://github.com/cloud-bulldozer/e2e-benchmarking";
LATEST_TAG=$(curl -s "https://api.github.com/repos/cloud-bulldozer/e2e-benchmarking/releases/latest" | jq -r '.tag_name');
TAG_OPTION="--branch $(if [ "$E2E_VERSION" == "default" ]; then echo "$LATEST_TAG"; else echo "$E2E_VERSION"; fi)";
git clone $REPO_URL $TAG_OPTION --depth 1
pushd e2e-benchmarking/workloads/kube-burner-ocp-wrapper

export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"

# LINES 26-59 ill be removed once PR https://github.com/kube-burner/kube-burner-ocp/pull/335 is merged and KUBE-BURNER version is updated
# GET KUBE-BURNER BINARY FROM THE BASTION HOST
SSH_ARGS="-i ${CLUSTER_PROFILE_DIR}/jh_priv_ssh_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"
bastion=$(cat ${CLUSTER_PROFILE_DIR}/address)

LAB=$(cat ${CLUSTER_PROFILE_DIR}/lab)
export LAB
LAB_CLOUD=$(cat ${CLUSTER_PROFILE_DIR}/lab_cloud || cat ${SHARED_DIR}/lab_cloud)
export LAB_CLOUD

scp -q ${SSH_ARGS} root@${bastion}:/root/${LAB}/${LAB_CLOUD}/kube-burner-ocp-cluster /tmp/kube-burner-ocp-cluster
chmod +x /tmp/kube-burner-ocp-cluster
md5sum /tmp/kube-burner-ocp-cluster

# UPDATE THE RUN.SH SCRIPT TO USE THE NEW KUBE-BURNER BINARY
# ⚠️ Define your file and the command you want to insert
FILE="./run.sh"
INSERT_COMMAND='cp /tmp/kube-burner-ocp-cluster /tmp/kube-burner-ocp'

LAST_LINE_NUM=$(grep -n "download_binary" "$FILE" | tail -1 | cut -d: -f1)

if [ -z "$LAST_LINE_NUM" ]; then
    echo "Error: 'download_binary' not found in $FILE."
    exit 1
fi


echo "Found last occurrence of 'download_binary' on line $LAST_LINE_NUM."
echo "Inserting command on line $((LAST_LINE_NUM + 1))..."

sed -i.bak "${LAST_LINE_NUM}a\\
${INSERT_COMMAND}" "$FILE"

echo "Insertion complete. A backup of the original file was saved as ${FILE}.bak"


# RUN THE WORKLOAD
if [ "$CHURN" == "true" ]; then
  EXTRA_FLAGS="${EXTRA_FLAGS} --churn-cycles ${CHURN_CYCLES} --churn-percent ${CHURN_PERCENT} --dpdk-devicepool ${SRIOV_DPDK_DEVICEPOOL} --net-devicepool ${SRIOV_NET_DEVICEPOOL}"
fi

WORKLOAD=rds-core PERFORMANCE_PROFILE=${PERFORMANCE_PROFILE} EXTRA_FLAGS="${EXTRA_FLAGS} --profile-type=${PROFILE_TYPE}" ./run.sh
