#!/usr/bin/env bash

set -ex

export INSTALLATION_NAMESPACE=${INSTALLATION_NAMESPACE:-openshift-cnv}
oc adm must-gather --image=quay.io/kubevirt/must-gather:latest --dest-dir="${ARTIFACT_DIR}" --timeout=10 \
   -- INSTALLATION_NAMESPACE="${INSTALLATION_NAMESPACE}" /usr/bin/gather --vms_details
