#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

# Get ODF Version x.y instead of x.y.z
ODF_VERSION=$(oc get csv -n "${ODF_NAMESPACE}" -l "operators.coreos.com/odf-operator.${ODF_NAMESPACE}=" -o=jsonpath='{.items[0].spec.version}' 2>/dev/null | cut -d'.' -f1,2 || true)

if [[ -z "${ODF_VERSION}" ]]; then
    echo "WARNING: ODF version could not be determined in namespace ${ODF_NAMESPACE} — skipping must-gather."
    mkdir -p "${ARTIFACT_DIR}/odf-must-gather"
    echo "SKIPPED: No ODF CSV found in namespace ${ODF_NAMESPACE}" > "${ARTIFACT_DIR}/odf-must-gather/SKIPPED_NO_CSV"
    exit 0
fi

# ODF must-gather
oc adm must-gather --image=registry.redhat.io/odf4/odf-must-gather-rhel9:v"$ODF_VERSION" --dest-dir="${ARTIFACT_DIR}/odf-must-gather"
