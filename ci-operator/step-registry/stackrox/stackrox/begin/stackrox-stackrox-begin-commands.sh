#!/bin/bash

if [[ -f .openshift-ci/begin.sh ]]; then
    exec .openshift-ci/begin.sh
else
    echo "A begin.sh script was not found in the target repo. Which is expected for release branches and migration."
    set -x
    pwd
    ls -l .openshift-ci || true
    set +x
fi
