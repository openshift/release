#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit extglob

# 1. Variables & Safety Checks
SECRETS_DIR="/run/secrets/ci.openshift.io/cluster-profile"
URL="https://gangway-ci.apps.ci.l2s4.p1.openshiftapps.com"
GANGWAY_API_TOKEN=$(cat "$SECRETS_DIR/gangway-api-token")

# Validate JSON_TRIGGER_LIST is set
: "${JSON_TRIGGER_LIST:?Environment variable JSON_TRIGGER_LIST is required.}"
WEEKLY_JOBS="$SECRETS_DIR/$JSON_TRIGGER_LIST"

#Get the day of the month
month_day=$(date +%-d)
# Get the current ISO week number (1-53)
week_num=$(date +%V)

# 2. Logic Gate: Determine if we should run today
echo "Checking execution rules for: $JSON_TRIGGER_LIST"

# Helper: Check if trigger list contains a string
has() { [[ "$JSON_TRIGGER_LIST" == *"$1"* ]]; }

if has "self-managed-lp-interop-jobs" && ! has "zstream" && ! has "gs_baremetal"; then
    # FIPS scenarios triggering logic 
    if has "fips"; then
        (( month_day > 7 )) && { echo "Not running FIPS scenarios past the first Monday of the month. Exiting."; exit 0; }
    else
        (( month_day <= 7 )) && { echo "Triggering FIPS scenarios in the first week of the month." }
    fi
 # GS Baremetal scenarios triggering logic     
elif has "gs_baremetal" && ! has "self-managed-lp-interop-jobs" && ! has "zstream" && ! has "fips"; then
    (( week_num % 2 != 0 )) && { echo "GS Baremetal only runs on even weeks. Exiting."; exit 0; }
fi

# 3. Early Exit for Rehearsals
[[ "${JOB_NAME:-}" == *"rehearse"* ]] && { echo "Job name contains 'rehearse'. Exiting."; exit 0; }

# 4. API Caller Function (Handles Retries)
call_api() {
    local method=$1 path=$2 max_retries=$3
    for ((i=1; i<=max_retries; i++)); do
        local code=$(curl -s -X "$method" -d '{"job_execution_type": "1"}' \
            -H "Authorization: Bearer $GANGWAY_API_TOKEN" \
            "$URL/v1/executions/${PROW_JOB_ID}" -w "%{http_code}" -o /dev/null)
        [[ "$code" == "200" ]] && return 0
        echo "Attempt $i: Received $code. Retrying in 60s..."
        sleep 60
    done
    return 1
}

# 5. Health Check
if [[ "${SKIP_HEALTH_CHECK:-false}" == "false" ]]; then
    echo "# Checking Gangway API Health..."
    call_api GET "$PROW_JOB_ID" 60 || { echo "Health check failed."; exit 1; }
fi

# 6. Trigger Jobs
echo "# Triggering active jobs from $JSON_TRIGGER_LIST"
failed_jobs=()

for job in $(jq -r '.[] | select(.active == true) | .job_name' "$WEEKLY_JOBS"); do
    echo "Processing: $job"
    if ! call_api POST "$job" 3; then
        echo "FAILED: $job"
        failed_jobs+=("$job")
    fi
done

# 7. Print the list of failed jobs after the loop completes
if (( ${#failed_jobs[@]} > 0 )); then
    echo "The following jobs failed to trigger and should be retriggered: ${failed_jobs[*]}"
    exit 1
else
    echo "All jobs triggered successfully."
fi
