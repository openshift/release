#!/bin/bash

set -exuo pipefail

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

MCE_VERSION=$(oc get "$(oc get multiclusterengines -oname)" -ojsonpath="{.status.currentVersion}" | cut -c 1-3)
if (( $(echo "$MCE_VERSION < 2.4" | bc -l) )); then
  echo "MCE version is less than 2.4, use HyperShift command"
  arch=$(arch)
  if [ "$arch" == "x86_64" ]; then
    downURL=$(oc get ConsoleCLIDownload hypershift-cli-download -o json | jq -r '.spec.links[] | select(.text | test("Linux for x86_64")).href') && curl -k --output /tmp/hypershift.tar.gz ${downURL}
    cd /tmp && tar -xvf /tmp/hypershift.tar.gz
    chmod +x /tmp/hypershift
    cd -
  fi
else
  echo "MCE version is greater than or equal to 2.4, need to extract HyperShift cli"
  oc extract secret/pull-secret -n openshift-config --to=/tmp --confirm
  HO_IMAGE=$(oc get deployment -n hypershift operator -ojsonpath='{.spec.template.spec.containers[*].image}')
  oc image extract "${HO_IMAGE}" --path /usr/bin/hypershift:/tmp --registry-config=/tmp/.dockerconfigjson
fi

CLUSTER_NAME="$(echo -n $PROW_JOB_ID|sha256sum|cut -c-20)"
/tmp/hypershift dump cluster --artifact-dir=$ARTIFACT_DIR \
--namespace local-cluster \
--dump-guest-cluster=true \
--name="${CLUSTER_NAME}"