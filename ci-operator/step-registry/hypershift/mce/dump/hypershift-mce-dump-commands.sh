#!/bin/bash

set -exuo pipefail

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

MCE_VERSION=$(oc get $(oc get multiclusterengines -oname) -ojsonpath="{.status.currentVersion}" | cut -c 1-3)
HYPERSHIFT_NAME=hcp
if (( $(echo "$MCE_VERSION < 2.4" | bc -l) )); then
  echo "MCE version is less than 2.4"
  HYPERSHIFT_NAME=hypershift
fi

arch=$(arch)
if [ "$arch" == "x86_64" ]; then
  downURL=$(oc get ConsoleCLIDownload ${HYPERSHIFT_NAME}-cli-download -o json | jq -r '.spec.links[] | select(.text | test("Linux for x86_64")).href') && curl -k --output /tmp/${HYPERSHIFT_NAME}.tar.gz ${downURL}
  cd /tmp && tar -xvf /tmp/${HYPERSHIFT_NAME}.tar.gz
  chmod +x /tmp/${HYPERSHIFT_NAME}
  cd -
fi

CLUSTER_NAME="$(echo -n $PROW_JOB_ID|sha256sum|cut -c-20)"
/tmp/hypershift dump cluster --artifact-dir=$ARTIFACT_DIR \
--namespace local-cluster \
--dump-guest-cluster=true \
--name="${CLUSTER_NAME}"