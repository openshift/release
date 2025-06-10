#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export XDG_CACHE_HOME="/tmp/cache"
export KUBECONFIG="$SHARED_DIR/kubeconfig"
# We need to switch to the default project, since the container doesn't have permission to see the project in kubeconfig context
oc project default

# we cannot use NAMESPACE env in servicemesh-sail-operator-e2e-lpinterop-ref.yaml since it overrides some global NAMESPACE env 
# which is used during post phase of step (so the pipeline tried to update secret in openshift operator namespace which resulted in error).
# Due to that, OPERATOR_NAMESPACE env is used in the step ref definition
export NAMESPACE=${OPERATOR_NAMESPACE}

ret_code=0
#execute test, do not terminate when there is some failure since we want to archive junit files
make test.e2e.ocp || ret_code=$?

# the junit file name must start with 'junit'
cp ./report.xml ${ARTIFACT_DIR}/junit-sail-e2e.xml

# report saved status code from make, in case test.e2e.ocp failed with panic in some test case (and junit doesn't contain error)
exit $ret_code
