#!/bin/bash

set -exuo pipefail

arch=$(arch)
if [ "$arch" == "x86_64" ]; then
  downURL=$(oc get ConsoleCLIDownload hypershift-cli-download -o json | jq -r '.spec.links[] | select(.text | test("Linux for x86_64")).href') && curl -k --output /tmp/hypershift.tar.gz ${downURL}
  cd /tmp && tar -xvf /tmp/hypershift.tar.gz
  chmod +x /tmp/hypershift
  cd -
fi

CLUSTER_NAME="$(echo -n $PROW_JOB_ID|sha256sum|cut -c-20)"
/tmp/hypershift dump cluster --artifact-dir=$ARTIFACT_DIR \
--namespace local-cluster \
--dump-guest-cluster=true \
--name="${CLUSTER_NAME}"