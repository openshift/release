#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi


# Machines
err_output=$(mktemp)
machine_output=$(mktemp)
oc get machine -n openshift-machine-api --selector machine.openshift.io/cluster-api-machine-type=master --no-headers -owide 1>${machine_output} 2>${err_output}

if grep -ir 'No resources found in openshift-machine-api namespace.' ${err_output}; then
    echo "WARN: No machines in openshift-machine-api namespace, skip checking"
    exit 0
fi

control_plane_nodes_count=$(cat "${machine_output}" | wc -l || true)
excepted_count=$(cat "${machine_output}" | awk '{print $1}' | grep -iE "master-[0-9]{1}$" | wc -l || true)

echo "control_plane_nodes_count: ${control_plane_nodes_count}"
echo "excepted_count: ${excepted_count}"

if (( ${excepted_count} < 1 )) || (( ${control_plane_nodes_count} < 1 )); then
    echo "ERROR: control plane nodes count or expected nodes count is less than 1, exit now."
    exit 1
fi


if [[ "${excepted_count}" != "${control_plane_nodes_count}" ]]; then
    echo "ERROR: One or more control plane machine name is not expected."
    exit 1
else
    echo "INFO: All control plane machine names are expected."
fi

echo "Machines:"
cat "${machine_output}"
