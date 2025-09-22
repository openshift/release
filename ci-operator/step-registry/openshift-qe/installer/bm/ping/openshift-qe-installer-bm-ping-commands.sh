#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

# Test remove after determining which is the correct directory
# <----
export prow_artifacts_base_url="https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/test-platform-results/logs"
export prow_artifacts_pr_base_url="https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/test-platform-results/pr-logs/pull/openshift_release"

job_id=$JOB_NAME
task_id=$BUILD_ID

if [[ "${JOB_TYPE}" == "presubmit" ]]; then
    prowjobjson_url="${prow_artifacts_pr_base_url}/${PULL_NUMBER}/${job_id}/${task_id}/prowjob.json"
else
    prowjobjson_url="${prow_artifacts_base_url}/${job_id}/${task_id}//prowjob.json"
fi

pull_number=$(curl -s "$prowjobjson_url" | jq -r '.metadata.labels."prow.k8s.io/refs.pull"')
echo $pull_number
# ---->