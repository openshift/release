#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

echo "default:x:$(id -u):$(id -g):Default Application User:/output:/sbin/nologin" >> /etc/passwd  #fix uid of container
cp /var/run/proxy-pkey/proxy-pkey ~/pkey; chmod 600 ~/pkey
proxyip="centos@$(cat /var/run/proxy-ip/proxy-ip)"

RESULTS_URL="https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/origin-ci-test/logs/$JOB_NAME/$BUILD_ID/$POLARION_STEP_RESULTS"
if [[ "$(echo $JOB_NAME | awk -F '-' '{print $1}')" == "rehearse" && "$JOB_TYPE" == "presubmit" ]]; then
  RESULTS_URL="https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/origin-ci-test/pr-logs/pull/openshift_release/$(echo $JOB_NAME | awk -F '-' '{print $2}')/$JOB_NAME/$BUILD_ID/$POLARION_STEP_RESULTS"
fi

echo "POLARION_PROPERTIES=\"$POLARION_PROPERTIES\""
echo "POLARION_RESULTS_URL=\"$RESULTS_URL\""
echo " "

ssh -i ~/pkey -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no $proxyip \
    "podman run -it --rm --pull=always \
    -e PROPERTIES=\"$POLARION_PROPERTIES\" \
    -e RESULTS_URL=$RESULTS_URL \
    quay.io/ocp-edge-qe/datarouter-upload:latest"
