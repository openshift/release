#!/bin/bash

export OPENSHIFT_CI_STEP_NAME="stackrox-stackrox-begin"

# Log rox-ci-image info for traceability.
echo "INFO: rox-ci-image:"
kubectl get imagestreamtag pipeline:root -o jsonpath='{.tag.from.name}{"\n"}{.image.dockerImageMetadata}{"\n"}' || true
echo "INFO: /i-am-rox-ci-image:"
cat /i-am-rox-ci-image || true

if [[ -f .openshift-ci/begin.sh ]]; then
    exec .openshift-ci/begin.sh
else
    echo "A begin.sh script was not found in the target repo. Which is expected for release branches and migration."
    set -x
    pwd
    ls -l .openshift-ci || true
    set +x
fi
