#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Extract additional repository archives
# mkdir -p {$OADP_GIT_DIR,$OADP_APPS_DIR,$PYCLIENT_DIR}
ls -ltr /alabama
ls -ltr $OADP_AUTOMATION_DIR

ls -ltr $OADP_GIT_DIR
ls -ltr $OADP_APPS_DIR
ls -ltr $PYCLIENT_DIR

# Setup Python Virtual Environment
echo "Create virtual environment and install required packages..."
python3 -m venv /alabama/venv
source /alabama/venv/bin/activate
python3 -m pip install ansible_runner
python3 -m pip install "${OADP_APPS_DIR}" --target "${OADP_GIT_DIR}/sample-applications/"
python3 -m pip install "${PYCLIENT_DIR}"
