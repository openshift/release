#!/bin/bash

if [[ -f .openshift-ci/end.sh ]]; then
    exec .openshift-ci/end.sh
else
    echo "An end.sh script was not found in the target repo. Which is expected for release branches and migration."
    set -x
    pwd
    ls -l .openshift-ci || true
    set +x
fi
