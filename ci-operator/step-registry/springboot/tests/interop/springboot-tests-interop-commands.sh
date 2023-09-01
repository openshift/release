#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

sleep 7200

# Set the API_URL value using the $SHARED_DIR/console.url file
CONSOLE_URL=$(cat $SHARED_DIR/console.url)
API_URL="https://api.${CONSOLE_URL#"https://console-openshift-console.apps."}:6443"
KUBEADMIN_PASSWORD=$(cat $SHARED_DIR/kubeadmin_password)

# Execute tests
/bin/bash /spring-boot-openshift-interop-tests/interop.sh ${API_URL} springboot kubeadmin <Openshift password>

sleep 7200