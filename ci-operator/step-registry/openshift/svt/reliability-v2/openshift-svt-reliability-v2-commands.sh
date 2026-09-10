#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

cat /etc/os-release
oc config view
oc projects
python --version

# oc is a superset of kubectl; symlink so reliability-v2 kubectl tasks work
if ! command -v kubectl &>/dev/null; then
  mkdir -p /tmp/bin
  ln -s "$(command -v oc)" /tmp/bin/kubectl
  export PATH="/tmp/bin:${PATH}"
fi

if [[ $REMOTE_CLIENT = "true" ]]; then
    cp /tmp/secret/kubeconfig ${ARTIFACT_DIR}/kubeconfig
    cp /tmp/secret/kubeadmin-password ${ARTIFACT_DIR}/kubeadmin-password
    cp ${SHARED_DIR}/runtime_env ${ARTIFACT_DIR}/runtime_env
    cp ${SHARED_DIR}/metadata.json ${ARTIFACT_DIR}/metadata.json
    sleep 3600
    exit 0
fi
pushd /tmp
# Disable tracing while reading and exporting the Slack API token.
set +x
SLACK_API_TOKEN=$(cat "/token/reliability-v2-slack-api-token")
export SLACK_API_TOKEN
set -x
git clone https://github.com/openshift/svt --depth=1
pushd svt/reliability-v2/utils
git clone https://github.com/cloud-bulldozer/performance-dashboards.git --depth=1
popd
pushd svt/reliability-v2
echo "========Start Reliability-v2 test for $RELIABILITY_DURATION========"
set +e
bash ./start.sh -n reliability -t "$RELIABILITY_DURATION" -c "$CONFIG_TEMPLATE" -r "$TOLERANCE_RATE"
set -e
# copy the reliability test result
popd
pushd svt/reliability-v2/reliability
cp reliability_result ${SHARED_DIR}/reliability_result
# start.sh can exit non-zero due to its cleanup handler killing an
# already-exited process, so check the result file to determine pass/fail.
if grep -q "Reliability Test Passed" reliability_result; then
    echo "Reliability test passed."
else
    echo "Reliability test failed."
    exit 1
fi