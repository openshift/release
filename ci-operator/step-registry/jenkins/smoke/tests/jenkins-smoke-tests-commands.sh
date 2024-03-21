#! /bin/bash

set -o nounset
set -o errexit
set -o pipefail

set -x

# Runs the smoke suite for OpenShift Jenkins
# 
# The KUBECONFIG environment variable must be set for the step to run to full completion.
#

echo "Starting step jenkins-smoke-tests."
if ! [[ -f ${KUBECONFIG} ]]; then
    echo "No kubeconfig found, skipping smoke tests for openshift jenkins."
    exit 1
fi

# Login for Interop
if test -f ${SHARED_DIR}/kubeadmin-password
then
  cp $KUBECONFIG /go/kubeconfig
  export KUBECONFIG=/go/kubeconfig

#Login for ROSA Classic and Hypershift platforms
else
  eval "$(cat "${SHARED_DIR}/api.login")"
fi

status=0

oc version

oc new-project test-jenkins

make smoke || status="$?" || :

# Copy Results and artifacts to $ARTIFACT_DIR
cp -r ./out ${ARTIFACT_DIR}/ 2>/dev/null || :

# Prepend junit_ to result xml files
rename '/TESTS-' '/junit_TESTS-' ${ARTIFACT_DIR}/out/smoke/TESTS-*.xml 2>/dev/null || :

echo "Step jenkins-smoke-tests completed."

exit $status
