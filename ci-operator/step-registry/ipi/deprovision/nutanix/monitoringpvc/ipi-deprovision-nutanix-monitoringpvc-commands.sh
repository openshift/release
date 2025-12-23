#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
  # shellcheck disable=SC1091
  source "${SHARED_DIR}/proxy-conf.sh"
fi
if oc -n openshift-monitoring get configmap cluster-monitoring-config &>/dev/null; then
  oc -n openshift-monitoring delete configmap cluster-monitoring-config
  oc -n openshift-monitoring delete pvc --all
  echo "$(date -u --rfc-3339=seconds) - Delete successful."
else
  echo "$(date -u --rfc-3339=seconds) - Configmap not found; no deletion necessary."
fi