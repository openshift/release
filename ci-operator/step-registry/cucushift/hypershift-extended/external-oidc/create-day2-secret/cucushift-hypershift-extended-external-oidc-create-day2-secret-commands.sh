#!/usr/bin/env bash

set -euo pipefail

if [ ! -f "${SHARED_DIR}/nested_kubeconfig" ]; then
  exit 1
fi

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

CONSOLE_CLIENT_SECRET="$(</var/run/hypershift-ext-oidc-app-console/client-secret)"
# The name must match the name of the empty secret created
# in step cucushift-hypershift-extended-external-oidc-enable.
CONSOLE_CLIENT_SECRET_NAME=authid-console-openshift-console


oc create secret generic "$CONSOLE_CLIENT_SECRET_NAME" -n openshift-config \
    --from-literal=clientSecret="$CONSOLE_CLIENT_SECRET" \
    --kubeconfig="${SHARED_DIR}/nested_kubeconfig"
