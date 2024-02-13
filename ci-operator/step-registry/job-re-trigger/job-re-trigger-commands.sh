#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

curl -X POST  "http://${SERVER_IP}:${SERVER_PORT}/openshift_ci_job_trigger" -d '{"job_name":"'"$JOB_NAME"'", "build_id": "'"$BUILD_ID"'", "prow_job_id":"'"$PROW_JOB_ID"'", "token":  "'"$TOKEN"'"}' -H "Content-Type: application/json" &