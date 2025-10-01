#!/bin/bash
set -o nounset
set -o pipefail
set -x

cat /etc/os-release
oc config view
oc projects
python --version

if [[ $REMOTE_CLIENT = "true" ]]; then
    cp /tmp/secret/kubeconfig ${ARTIFACT_DIR}/kubeconfig
    cp /tmp/secret/kubeadmin-password ${ARTIFACT_DIR}/kubeadmin-password
    cp ${SHARED_DIR}/kubeconfig ${ARTIFACT_DIR}/kubeconfig
    cp ${SHARED_DIR}/runtime_env ${ARTIFACT_DIR}/runtime_env
    cp ${SHARED_DIR}/metadata.json ${ARTIFACT_DIR}/metadata.json
    sleep 3600
    exit 0
fi
pushd /tmp
SLACK_API_TOKEN=$(cat "/token/reliability-v2-slack-api-token")
export SLACK_API_TOKEN
git clone https://github.com/openshift/svt --depth=1
pushd svt/reliability-v2/utils
git clone https://github.com/cloud-bulldozer/performance-dashboards.git --depth=1
popd
pushd svt/reliability-v2
echo "========Start Reliability-v2 test for $RELIABILITY_DURATION========"
set +e
bash -x ./start.sh -n reliability -t $RELIABILITY_DURATION -c $CONFIG_TEMPLATE -r $TOLERANCE_RATE
result=$?
set -e
# copy the reliability test result
popd
pushd svt/reliability-v2/reliability
cp reliability_result ${SHARED_DIR}/reliability_result
if [[ $result -ne 0 ]]; then
    exit 1
fi 