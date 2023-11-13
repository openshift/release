#!/usr/bin/env bash

set -e

cd /tmp/devspaces/scripts
cp /var/run/secrets/ci.openshift.io/multi-stage/kubeconfig ./
oc login "$(oc whoami --show-server)" --username=kubeadmin --password="$(cat $SHARED_DIR/kubeadmin-password)" --insecure-skip-tls-verify=true
./execute-test-harness.sh

cp -r /tmp/devspaces/scripts/test-run-results ${ARTIFACT_DIR}