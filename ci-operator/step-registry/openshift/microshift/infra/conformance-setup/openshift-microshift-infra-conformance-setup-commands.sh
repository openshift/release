#!/bin/bash
set -xeuo pipefail

# shellcheck disable=SC1091
source "${SHARED_DIR}/ci-functions.sh"
ci_script_prologue

# Look at sos step for the exit codes definitions
function finalize()
{
  if [[ "$?" -ne "0" ]] ; then
    echo "7" >> "${SHARED_DIR}/install-status.txt"
  else
    echo "0" >> "${SHARED_DIR}/install-status.txt"
  fi
}

cp /go/src/github.com/openshift/microshift/origin/skip.txt "${SHARED_DIR}/conformance-skip.txt"
cp "${SHARED_DIR}/conformance-skip.txt" "${ARTIFACT_DIR}/conformance-skip.txt"

# Disable workload partitioning for annotated pods to avoid throttling.
ssh "${INSTANCE_PREFIX}" "sudo sed -i 's/resources/#&/g' /etc/crio/crio.conf.d/11-microshift-ovn.conf"
ssh "${INSTANCE_PREFIX}" "sudo systemctl daemon-reload"
# Just for safety, restart everything from scratch.
ssh "${INSTANCE_PREFIX}" "echo 1 | sudo microshift-cleanup-data --all --keep-images"
ssh "${INSTANCE_PREFIX}" "sudo systemctl restart crio"
# Do not enable microshift to force failures should a microshift restart happen
ssh "${INSTANCE_PREFIX}" "sudo systemctl start microshift"
