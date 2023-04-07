#!/bin/bash

set -u
set -e
set -o pipefail

URL=$(oc whoami --show-server)
export URL

ADMIN_PASSWORD=$(cat "$KUBEADMIN_PASSWORD_FILE")
export ADMIN_PASSWORD

export ADMIN_USERNAME="kubeadmin"

export FUSE_ONLINE_NAMESPACE="fuse-online"

oc login --insecure-skip-tls-verify=true -u "${ADMIN_USERNAME}" -p "${ADMIN_PASSWORD}" "$(oc whoami --show-server)"

oc create --as system:admin user kubeadmin
oc create --as system:admin identity kube:admin
oc create --as system:admin useridentitymapping kube:admin kubeadmin
oc adm policy --as system:admin add-cluster-role-to-user cluster-admin kubeadmin

oc new-project test-runner

oc adm policy add-scc-to-user anyuid -z default

oc new-app --name test-runner --image="$FUSE_ONLINE_TEST_RUNNER" -e ADMIN_USERNAME=$ADMIN_USERNAME -e ADMIN_PASSWORD=$(cat $KUBEADMIN_PASSWORD_FILE) -e URL=$(oc whoami --show-server) -e NAMESPACE=$FUSE_ONLINE_NAMESPACE

# sleep for testing
sleep 1400

# need to copy out the test run artifacts from /test-run-results

