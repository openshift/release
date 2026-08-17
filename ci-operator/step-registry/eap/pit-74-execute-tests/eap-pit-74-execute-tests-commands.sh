#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

shopt -s nullglob

# Archive results function
function cleanup-collect() {
    #cleanup
    echo "Running cleanup; deleting tests.properties file"
    rm test.properties
    echo "Collecting maven results into {$ARTIFACT_DIR}"
    cp ./test-eap/target/surefire-reports/TEST*.xml $ARTIFACT_DIR
    rename TEST junit_TEST ${ARTIFACT_DIR}/TEST*.xml
}

# Post test execution
trap 'cleanup-collect' SIGINT SIGTERM ERR EXIT

# Copy kubeconfig file into current dir
cp /var/run/secrets/ci.openshift.io/multi-stage/kubeconfig ./

KUBEADMIN_PWD=$(cat "$SHARED_DIR"/kubeadmin-password)
KUBECONFIG=kubeconfig

export KUBEADMIN_PWD
export KUBECONFIG

echo "Login to the cluster as kubeadmin"
oc login -u kubeadmin -p $KUBEADMIN_PWD

OPENSHIFT_API_URL=$(oc config view --minify -o jsonpath='{.clusters[*].cluster.server}')
OPENSHIFT_API_TOKEN=$(oc whoami -t)

export OPENSHIFT_API_URL
export OPENSHIFT_API_TOKEN

# Applying cluster credentials in test.properties file
cat << EOF > test.properties
xtf.openshift.url=$OPENSHIFT_API_URL
xtf.openshift.admin.username=kubeadmin
xtf.openshift.admin.password=$KUBEADMIN_PWD
xtf.openshift.admin.token=$OPENSHIFT_API_TOKEN
xtf.openshift.master.username=xpaasqe
xtf.openshift.master.password=xpaasqe
xtf.openshift.master.token=$OPENSHIFT_API_TOKEN
xtf.config.master.jump.ssh_hostname=api.pit-39mb.dynamic.xpaas
xtf.config.master.jump.ssh_username=core
xtf.config.master.ssh_key_path=/home/hudson/.ssh/id_rsa
xtf.config.master.ssh_username=core

xtf.openshift.namespace=pit
xtf.bm.namespace=pit-builds
EOF

echo "Executing EAP 74 tests"
# Note: When executing maven we don't want the raw output to be printed into the pod logs, due to cluster security issues.
# Therefore we're using the tmp log file which will not be collected.
mvn clean -e test -Dmaven.repo.local=./repo -Dxtf.operator.properties.skip.installation=true -P74-openjdk11,eap-pit-74 --log-file eap-74.txt