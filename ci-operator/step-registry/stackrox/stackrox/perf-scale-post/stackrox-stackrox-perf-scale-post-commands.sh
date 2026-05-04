#!/bin/bash

export OPENSHIFT_CI_STEP_NAME="stackrox-stackrox-perf-scale-post"

if [[ -f scripts/ci/jobs/ocp-perf-scale-tests-post.sh ]]; then
    exec scripts/ci/jobs/ocp-perf-scale-tests-post.sh
else
    echo "ocp-perf-scale-tests-post.sh script was not found in the target repo."
    echo "This is expected for branches that don't have the post script yet."
    echo "Skipping diagnostic collection."
fi
