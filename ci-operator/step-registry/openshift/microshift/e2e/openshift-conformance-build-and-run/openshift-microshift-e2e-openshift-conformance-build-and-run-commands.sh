#!/bin/bash
set -xeuo pipefail

# shellcheck disable=SC1091
source "${SHARED_DIR}/ci-functions.sh"
ci_script_prologue

DEST_DIR="/tmp/conformance"
ROOT_DIR="/home/${HOST_USER}/microshift"

cat > /tmp/run.sh <<EOF
set -xe
if [[ "$JOB_TYPE" == "presubmit" ]]; then
    export MICROSHIFT_SKIP_MONITOR_TESTS=true
fi
sudo cat /var/lib/microshift/resources/kubeadmin/kubeconfig > /tmp/kubeconfig
mkdir -p ${DEST_DIR}
if [ -f "${ROOT_DIR}/origin/run.sh" ]; then
    DEST_DIR="${DEST_DIR}" \
    KUBECONFIG="/tmp/kubeconfig" \
    RESTRICTED="${RESTRICTED}" \
    "${ROOT_DIR}/origin/run.sh"
fi
EOF
chmod +x /tmp/run.sh

scp /tmp/run.sh "${INSTANCE_PREFIX}":/tmp
trap 'scp -r "${INSTANCE_PREFIX}":"${DEST_DIR}" "${ARTIFACT_DIR}"' EXIT
ssh "${INSTANCE_PREFIX}" "bash -x /tmp/run.sh" 
