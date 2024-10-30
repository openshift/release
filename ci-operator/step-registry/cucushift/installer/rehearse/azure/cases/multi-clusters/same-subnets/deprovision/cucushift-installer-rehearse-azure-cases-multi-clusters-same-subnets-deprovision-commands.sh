#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function save_logs() {
    echo "Copying the Installer logs and metadata to the artifacts directory..."
    cp ${work_dir}/.openshift_install.log "${ARTIFACT_DIR}"
    cp ${work_dir}/metadata.json "${ARTIFACT_DIR}"
}

trap 'save_logs' EXIT TERM

export AZURE_AUTH_LOCATION=${CLUSTER_PROFILE_DIR}/osServicePrincipal.json

work_dir=$(mktemp -d)
cp "${SHARED_DIR}/cluster-2-metadata.json" ${work_dir}/metadata.json

echo "Destroy cluster..."
openshift-install destroy cluster --dir ${work_dir}
