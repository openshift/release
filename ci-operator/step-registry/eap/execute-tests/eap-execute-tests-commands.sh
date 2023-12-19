#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

shopt -s nullglob

#Debug test execution
trap 'sleep 4h' EXIT

# Copy kubeconfig file into current dir
cp /var/run/secrets/ci.openshift.io/multi-stage/kubeconfig ./

KUBEADMIN_PWD=$(cat "$SHARED_DIR"/kubeadmin-password)
KUBECONFIG=kubeconfig

export KUBEADMIN_PWD
export KUBECONFIG

# oc login as kube:admin
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

# TOKEN=$(oc whoami -t)
# oc delete configmap test-properties -n "${1}" || true
# oc create configmap test-properties -n "${1}" --from-file=/tmp/test.properties

# Execute tests
mvn clean -e test -Dmaven.repo.local=./repo -Dxtf.operator.properties.skip.installation=true -P74-openjdk11,eap-pit-74 --log-file eap-74.txt
# Tag for 4.15:
mvn clean -e test -Dmaven.repo.local=./repo -P74-openjdk11,eap-pit-7.4.x --log-file eap_74x.txt

#cleanup
rm test.properties