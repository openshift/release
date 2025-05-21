#!/bin/bash

set -e

_curl_qm() {
    curl \
        -s \
        --resolve "${queue_manager_tls_host}:443:${queue_manager_tls_ip}" \
        --cacert "$queue_manager_tls_crt" \
        -H "Authorization: Bearer $queue_manager_auth_token" \
        "$@" \
        2>/dev/null
}

_curl_jobs_submit() {
    _curl_qm -X POST "https://$queue_manager_tls_host/jobs/submit?pullnumber=$1&pull_pull_sha=$2&pickup=1"
}

_curl_jobs_retrieve() {
    _curl_qm -X POST "https://$queue_manager_tls_host/jobs/retrieve?uuid=$1"
}

_json_get() {
    printf '%s' "$1" | jq -r "$2" 2>/dev/null
}

queue_manager_tls_host=$(cat "/var/run/token/e2e-test/queue-manager-tls-host")
queue_manager_tls_ip=$(cat "/var/run/token/e2e-test/queue-manager-tls-ip")
queue_manager_auth_token=$(cat "/var/run/token/jenkins-secrets/queue-manager-auth-token")
queue_manager_tls_crt="/var/run/token/jenkins-secrets/queue-manager-tls-crt"

echo "Handling pull request https://github.com/openshift/dpu-operator/pull/$PULL_NUMBER , git-sha=$PULL_PULL_SHA"

submit_response="$(_curl_jobs_submit "$PULL_NUMBER" "$PULL_PULL_SHA")"

return_code="$(_json_get "$submit_response" '.return_code')"
if [ "$return_code" -ne 200 ] && [ "$return_code" -ne 202 ] ; then
    echo "failure to start job: $return_code"
    exit 1
fi

uuid="$(_json_get "$submit_response" '.message')"

echo "Started job in queue manager: UUID=$uuid, return_code=$return_code. Start polling"

while true ; do
    retrieve_response="$(_curl_jobs_retrieve "$uuid")"

    return_code="$(_json_get "$retrieve_response" '.return_code')"

    if [ "$return_code" -eq 102 ] ; then
        # Job still running.
        sleep 15
        continue
    fi

    result_msg="$(_json_get "$retrieve_response" '.result_msg')"

    if [ "$return_code" -ne 200 ] ; then
        echo "failure checking for job $uuid [$return_code]: $result_msg"
        exit 1
    fi

    echo "==============================================="
    _json_get "$retrieve_response" '.console_logs'
    echo "==============================================="

    job_status="$(_json_get "$retrieve_response" '.message')"
    echo "= Job $uuid completed with [$job_status]: $result_msg"
    echo "==============================================="

    if [ "$job_status" = 'SUCCESS' ] ; then
        exit 0
    fi
    exit 1
done
