#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

OADP_GIT_DIR="/alabama/cspi"
OADP_APPS_DIR="/alabama/oadpApps"
PYCLIENT_DIR="/alabama/pyclient"

# Extract additional repository archives
ls -ltr /alabama
mkdir -p "${OADP_GIT_DIR}"
mkdir -p "${OADP_APPS_DIR}"
mkdir -p "${PYCLIENT_DIR}"
echo "Extract /home/jenkins/oadp-e2e-qe.tar.gz"
tar -xf /home/jenkins/oadp-e2e-qe.tar.gz -C "${OADP_GIT_DIR}" --strip-components 1
echo "Extract /home/jenkins/oadp-apps-deployer.tar.gz"
tar -xf /home/jenkins/oadp-apps-deployer.tar.gz -C "${OADP_APPS_DIR}" --strip-components 1
echo "Extract /home/jenkins/mtc-python-client.tar.gz"
tar -xf /home/jenkins/mtc-python-client.tar.gz -C "${PYCLIENT_DIR}" --strip-components 1

# Setup Python Virtual Environment
echo "Create virtual environment and install required packages..."
python3 -m venv /alabama/venv
source /alabama/venv/bin/activate
python3 -m pip install ansible_runner
python3 -m pip install "${OADP_APPS_DIR}" --target "${OADP_GIT_DIR}/sample-applications/"
python3 -m pip install "${PYCLIENT_DIR}"
