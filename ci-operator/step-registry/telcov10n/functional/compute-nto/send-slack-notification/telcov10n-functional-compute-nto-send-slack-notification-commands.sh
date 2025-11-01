#!/bin/bash
set -e
set -o pipefail

env

# Skip if job type is presubmit
# if [ "$JOB_TYPE" = "presubmit" ]; then
#   echo "JOB_TYPE=presubmit — skipping script"
#   exit 0
# fi

STATUS_JOB=$(cat ${SHARED_DIR}/job_status.txt)

if [ "$STATUS_JOB" = "Passed" ]; then
  echo "Job Passed — not sending slack notification"
  exit 0
fi

pip install requests jinja2
curl -L https://raw.githubusercontent.com/openshift-kni/eco-ci-cd/refs/heads/main/playbooks/infra/scripts/send-slack-notification.py -o /tmp/send-slack-notification.py
python3 /tmp/send-slack-notification.py \
  --webhook-url "$(cat ${SHARED_DIR}/slack-webhook-url)" \
  --version "$(cat ${SHARED_DIR}/cluster_version)" \
  --job-name ${JOB_NAME} \
  --link "https://prow.ci.openshift.org/view/gs/test-platform-results/logs/${JOB_NAME}/${BUILD_ID}" \
  --users rshemtov mniranja snarula \
  --dry-run
