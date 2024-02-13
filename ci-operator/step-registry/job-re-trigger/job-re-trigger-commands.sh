#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

SECRETS_DIR=/run/secrets/ci.openshift.io/cluster-profile
SECRET_PATH="openshift-ci-job-trigger"

SERVER_IP=$(cat $SECRETS_DIR/$SECRET_PATH-server-ip)
SERVER_PORT=$(cat $SECRETS_DIR/$SECRET_PATH-server-port)
TOKEN=$(cat $SECRETS_DIR/$SECRET_PATH-token)

curl -X POST  "http://${SERVER_IP}:${SERVER_PORT}/openshift_ci_job_trigger" -d '{"job_name":"'"$JOB_NAME"'", "build_id": "'"$BUILD_ID"'", "prow_job_id":"'"$PROW_JOB_ID"'", "token":  "'"$TOKEN"'"}' -H "Content-Type: application/json" &