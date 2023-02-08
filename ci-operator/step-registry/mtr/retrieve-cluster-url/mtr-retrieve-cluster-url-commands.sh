#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Get the apps URL and pass it to env.sh for the mtr-runner container to use
URL=$(oc get route -n openshift-console console -o jsonpath='{.spec.host}')
CLUSTER_URL=${URL#"console-openshift-console."}
echo "${CLUSTER_URL}" > ${SHARED_DIR}/cluster_url