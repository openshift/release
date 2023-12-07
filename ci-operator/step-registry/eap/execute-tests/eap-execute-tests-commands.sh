#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

shopt -s nullglob

#Debug test execution
sleep 4h

CONSOLE_URL=$(cat "$SHARED_DIR"/console.url)
export API_URL="https://api.${CONSOLE_URL#"https://console-openshift-console.apps."}:6443"
export KUBEADMIN_PWD=$(cat "$SHARED_DIR"/kubeadmin-password)
export OCM_TOKEN=$(cat /var/run/secrets/ci.openshift.io/cluster-profile/ocm-token)
export KUBECONFIG=/var/run/secrets/ci.openshift.io/multi-stage/kubeconfig

# login to oc
# oc login --token=$OCM_TOKEN --server=$SERVER
#oc login $API_URL \
#  --username="kubeadmin" \
#  --password=$KUBEADMIN_PWD \
#  --insecure-skip-tls-verify=true

export TOKEN=$(oc whoami -t)

# Applying cluster credentials in test.properties file
cat << EOF > test.properties
xtf.openshift.url=$API_URL
xtf.openshift.admin.username=kubeadmin
xtf.openshift.admin.password=$KUBEADMIN_PWD
xtf.openshift.admin.token=$TOKEN
xtf.openshift.master.username=xpaasqe
xtf.openshift.master.password=xpaasqe
xtf.openshift.master.token=$TOKEN
xtf.config.master.jump.ssh_hostname=api.pit-39mb.dynamic.xpaas
xtf.config.master.jump.ssh_username=core
xtf.config.master.ssh_key_path=/home/hudson/.ssh/id_rsa
xtf.config.master.ssh_username=core

xtf.openshift.namespace=pit
xtf.bm.namespace=pit-builds
EOF

# oc delete configmap test-properties -n "${1}" || true
# oc create configmap test-properties -n "${1}" --from-file=/tmp/test.properties

# Execute tests
mvn clean -e test -Dmaven.repo.local=./repo -Dxtf.operator.properties.skip.installation=true -P74-openjdk11,eap-pit-74
# Tag for 4.15:
# mvn clean -e test -Dmaven.repo.local=./repo -P74-openjdk11,eap-pit-7.4.x