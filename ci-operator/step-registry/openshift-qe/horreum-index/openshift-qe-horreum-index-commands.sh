#!/bin/bash

if [[ "${USE_HORREUM_WEBHOOK}" == "true" ]]; then
    WEBHOOK_USER=$(cat "/horreum-secret/horreum-webhook-user")
    
    export artifacts_base_url="https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/test-platform-results/logs"
    export artifacts_pr_base_url="https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/test-platform-results/pr-logs/pull/openshift_release"
    job_id=$JOB_NAME
    task_id=$BUILD_ID
    
    if [[ "${JOB_TYPE}" == "presubmit" ]]; then
        artifacts_url="${artifacts_pr_base_url}/${PULL_NUMBER}/${job_id}/${task_id}/artifacts"
    else
        artifacts_url="${artifacts_base_url}/${job_id}/${task_id}/artifacts"
    fi
    
    benchmark_name="${BENCHMARK_NAME}"
    
    WEBHOOK_URL="https://snake-curious-easily.ngrok-free.app"
    JSON_DATA='{"jobName":"kube-burner-poc","parameters":{"ARTIFACTS_URL":"'"$artifacts_url"'", "BENCHMARK_NAME":"'"$benchmark_name"'", "BUCKET_NAME":"test-platform-results", "TYPE":"report"}}'
    
    curl -X POST \
         -u "user:$WEBHOOK_USER"  \
         --header "Content-Type: application/json" \
         --retry 5 \
         "$WEBHOOK_URL" \
         -d "$JSON_DATA"

fi
