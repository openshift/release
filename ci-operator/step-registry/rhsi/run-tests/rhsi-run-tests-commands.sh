#!/bin/bash

set -u
set -e
set -o pipefail

export PUBKUBECONFIG=$KUBECONFIG

export PRIVKUBECONFIG=$KUBECONFIG

export WAITLIMIT=300

cd /app

status=0

./run-test.sh || status="$?" || :

mkdir -p $ARTIFACT_DIR/result

# Copy results to ARTIFACT_DIR
cp -r /result/* $ARTIFACT_DIR/result 2>/dev/null || :
cp -r /tmp/test.out $ARTIFACT_DIR/result 2>/dev/null || :

# Prepend junit_ to result xml files
for f in ${ARTIFACT_DIR}/result/*.xml; do nf="$(echo $f | sed -e 's/\/junit/\/junit_rhsi/')" ; mv -- "$f" "$nf"; done || :

exit $status

