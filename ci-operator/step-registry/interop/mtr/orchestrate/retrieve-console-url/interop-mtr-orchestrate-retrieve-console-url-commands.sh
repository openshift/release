#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Get the apps URL and pass it to env.sh for the mtr-runner container to use
URL=$(oc get route -n openshift-console console -o jsonpath='{.spec.host}')
APPS_URL=${URL#"console-openshift-console."}
echo "${APPS_URL}" > ${SHARED_DIR}/apps_url