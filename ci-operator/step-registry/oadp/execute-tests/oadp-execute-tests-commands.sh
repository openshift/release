#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

SECRETS_DIR="/tmp/secrets"
OADP_GH_PAT=$(cat ${SECRETS_DIR}/oadp/oadp-gh-pat)
OADP_GH_USER=$(cat ${SECRETS_DIR}/oadp/oadp-gh-user)


readonly OADP_GIT_DIR="${HOME}/cspi"
readonly OADP_APPS_DIR="${HOME}/oadpApps"
readonly PYCLIENT_DIR="${HOME}/pyclient"
mkdir -p "${OADP_GIT_DIR}"
mkdir -p /tmp/test-settings
touch /tmp/test-settings/default_settings.json
mkdir -p "${OADP_APPS_DIR}"
mkdir -p "${PYCLIENT_DIR}"


echo "Annotate oadp namespace"
oc annotate --overwrite namespace/openshift-adp volsync.backube/privileged-movers='true'


echo "AWS info"
cp "${CLUSTER_PROFILE_DIR}/.awscred" /tmp/test-settings/aws_creds
echo "End of AWS info"



echo "clone oadp-e2e-qe"
git clone --branch master https://${OADP_GH_USER}:${OADP_GH_PAT}@github.com/CSPI-QE/oadp-e2e-qe "${OADP_GIT_DIR}"

echo "clone appsdeployer"
git clone --branch master https://${OADP_GH_USER}:${OADP_GH_PAT}@github.com/CSPI-QE/oadp-apps-deployer "${OADP_APPS_DIR}"

echo "clone pyclient"
git clone --branch master https://${OADP_GH_USER}:${OADP_GH_PAT}@github.com/CSPI-QE/oadp-apps-deployer "${PYCLIENT_DIR}"


cd /alabama/oadpApps
python3 -m pip install pip --upgrade
python3 -m venv test
source test/bin/activate
python3 -m pip install . --target "${OADP_GIT_DIR}/sample-applications/"

echo "pip install python-client"
cd /alabama/pyclient

python3 -m pip install . 


echo "pip install ansible_runner"
pip install ansible_runner


echo "chdir to OADP_GIT_DIR"
cd /alabama/cspi

export ANSIBLE_REMOTE_TMP=/tmp/


#echo "EXPORT TMP AS HOME DIR"
#export HOME=/tmp/

echo "sleep"
sleep 600

echo "Run tests from CLI"
NAMESPACE=openshift-adp EXTRA_GINKGO_PARAMS=--ginkgo.focus=test-upstream bash /alabama/cspi/test_settings/scripts/test_runner.sh 
#NAMESPACE=openshift-adp bash /alabama/cspi/test_settings/scripts/test_runner.sh 


ls -laht /alabama/cspi/output_files

echo "finished"