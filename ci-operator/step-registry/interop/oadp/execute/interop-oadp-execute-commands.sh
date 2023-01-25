#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

SECRETS_DIR="/tmp/secrets"
OADP_GH_PAT=$(cat ${SECRETS_DIR}/oadp/oadp-gh-pat)


readonly OADP_GIT_DIR="${HOME}/cspi"
mkdir -p "${OADP_GIT_DIR}"
mkdir -p /tmp/test-settings
touch /tmp/test-settings/default_settings.json


echo "Annotate oadp namespace"
oc annotate --overwrite namespace/openshift-adp volsync.backube/privileged-movers='true'


echo "AWS info"
cp "${CLUSTER_PROFILE_DIR}/.awscred" /tmp/test-settings/aws_creds
echo "End of AWS info"


echo "ls /usr/local/go/bin"
ls -laht /usr/local/go/bin

git clone --branch master https://madunn:${OADP_GH_PAT}@github.com/CSPI-QE/oadp-e2e-qe "${OADP_GIT_DIR}"


echo "CLOUD_PROVIDER"
oc get infrastructures cluster -o jsonpath='{.status.platform}' | awk '{print tolower($0)}'

echo "chdir to OADP_GIT_DIR"
cd /alabama/cspi

cat > ./ansible.cfg << EOF
[defaults]
 local_tmp = /tmp/
 remote_tmp = /tmp/
 ANSIBLE_DEBUG=true
 ANSIBLE_VERBOSITY=4
EOF


cat >> /alabama/cspi/sample-applications/ansible/ansible.cfg << EOF
ansible_verbosity=4
ansible_debug=true
EOF

echo "PWD"
pwd

echo "EXPORT TMP AS HOME DIR"
export HOME=/tmp/
echo "DONE"

sleep 600

echo "Run tests from CLI"
NAMESPACE=openshift-adp EXTRA_GINKGO_PARAMS=--ginkgo.focus=test-upstream bash /alabama/cspi/test_settings/scripts/test_runner.sh 
#NAMESPACE=openshift-adp bash /alabama/cspi/test_settings/scripts/test_runner.sh 


ls -laht /alabama/cspi/output_files

echo "finished"