#!/bin/bash

set -o errexit
set -o pipefail

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

proxy="$(<"${CLUSTER_PROFILE_DIR}/proxy")"

if [ "${AGENT_BM_HOSTS_IN_INSTALL_CONFIG}" != "true" ]; then
  echo "Skipping BMC check step"
  exit 0
fi

# wait for bmh to be provisioned
WAIT="true"
while [ $WAIT == "true" ]; do
    sleep 30
    WAIT=false
    for bmh in $(oc get bmh -o name -n openshift-machine-api); do
          if ! [[ $(oc get $bmh -n openshift-machine-api -o jsonpath --template '{.status.provisioning.state}') == "externally provisioned" ]]; then
                WAIT=true
          fi
    done
done

# shellcheck disable=SC2034
http_proxy="${proxy}" https_proxy="${proxy}" HTTP_PROXY="${proxy}" HTTPS_PROXY="${proxy}" \
oc get bmh -n openshift-machine-api | tee "${ARTIFACT_DIR}/get_bmh.txt"
for bmh in $(oc get bmh -o name -n openshift-machine-api); do
  # shellcheck disable=SC2154
  oc describe "${bmh}" -n openshift-machine-api | tee -a "${ARTIFACT_DIR}/describe_bmh.txt"
done
