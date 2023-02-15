#!/bin/bash

set -u
set -e
set -o pipefail

export PUBKUBECONFIG=$KUBECONFIG

export PRIVKUBECONFIG=$KUBECONFIG

export QUIET=TRUE

cd /app

status=0

./run-tests.sh || status="$?" || :

mkdir -p $ARTIFACT_DIR/results

# Copy results to ARTIFACT_DIR
cp /results $ARTIFACT_DIR/results

# Prepend junit_ to result xml files

exit $status

