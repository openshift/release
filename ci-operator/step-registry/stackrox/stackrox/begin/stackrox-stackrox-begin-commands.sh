#!/bin/bash

if [[ "${JOB_NAME}" =~ ^branch.*master-ocp-4-14-merge-(qa|ui) ]]; then
    echo "Forced failure to unblock stuck CI jobs"
    exit 1
fi

export OPENSHIFT_CI_STEP_NAME="stackrox-stackrox-begin"

if [[ -f .openshift-ci/begin.sh ]]; then
    exec .openshift-ci/begin.sh
else
    echo "A begin.sh script was not found in the target repo. Which is expected for release branches and migration."
    set -x
    pwd
    ls -l .openshift-ci || true
    set +x
fi
