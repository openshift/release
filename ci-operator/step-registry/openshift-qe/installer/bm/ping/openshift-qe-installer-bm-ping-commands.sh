#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

# Test remove after determining which is the correct directory
# <----
echo "LS DIR ARTIFACT_DIR: ${ARTIFACT_DIR}"
ls -l $ARTIFACT_DIR

echo "LS DIR: PWD"
ls -l $PWD

export prow_artifacts_base_url="https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/test-platform-results/logs"
task_id=$BUILD_ID
job_id=$JOB_NAME
prowjobjson_url="${prow_artifacts_base_url}/${job_id}/${task_id}/prowjob.json"
pull_number=$(curl -s "$prowjobjson_url" | jq -r '.metadata.labels."prow.k8s.io/refs.pull"')
echo $pull_number
# ---->