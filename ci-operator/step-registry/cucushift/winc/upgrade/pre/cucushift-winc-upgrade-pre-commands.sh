#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

WMCO_NAMESPACE="openshift-windows-machine-config-operator"
WMCO_SUBSCRIPTION="windows-machine-config-operator"

OLD_CSV=$(oc get subscription "${WMCO_SUBSCRIPTION}" -n "${WMCO_NAMESPACE}" -o jsonpath='{.status.installedCSV}')

if [[ -z "${OLD_CSV}" ]]; then
    echo "ERROR: No WMCO CSV found in ${WMCO_NAMESPACE}"
    oc get csv -n "${WMCO_NAMESPACE}" -o yaml
    exit 1
fi

echo "Pre-upgrade WMCO CSV: ${OLD_CSV}"
echo "${OLD_CSV}" > "${SHARED_DIR}/wmco-csv-pre-upgrade"
