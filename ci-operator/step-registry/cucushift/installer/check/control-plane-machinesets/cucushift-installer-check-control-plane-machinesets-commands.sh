#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# check if controlplanemachinesets is supported by the IaaS and the OCP version
# return 0 if controlplanemachinesets is supported, otherwise 1
function hasCPMS() {
    ret=1

    case "${CLUSTER_TYPE}" in
    aws*)
        # 4.12+
        REQUIRED_OCP_VERSION="4.12"
        ;;
    azure*)
        # 4.13+
        REQUIRED_OCP_VERSION="4.13"
        ;;
    gcp)
        # 4.13+
        REQUIRED_OCP_VERSION="4.13"
        ;;
    nutanix*)
        # 4.14+
        REQUIRED_OCP_VERSION="4.14"
        ;;
    vsphere*)
        # 4.15+
        if [[ "${FEATURE_SET}" == "TechPreviewNoUpgrade" ]]; then
            REQUIRED_OCP_VERSION="4.15"
        else
            REQUIRED_OCP_VERSION="4.16"
        fi
        ;;
    *)
        return ${ret}
        ;;
    esac    

    if [ -n "${version}" ] && [ "$(printf '%s\n' "${REQUIRED_OCP_VERSION}" "${version}" | sort --version-sort | head -n1)" = "${REQUIRED_OCP_VERSION}" ]; then
        ret=0
    fi
    return ${ret}
}

# check if the cluster is by IPI or UPI
# return 0 if it is an IPI cluster, otherwise 1
function isIPI() {
    #oc get machines -n openshift-machine-api -o json | jq -r '.items[].metadata.labels."machine.openshift.io/cluster-api-machine-role"' | grep master
    oc get cm -n openshift-config openshift-install -o yaml
    if [ $? -eq 0 ]; then
        # an IPI cluster
        return 0
    else
        # a UPI cluster
        return 1
    fi
}

# check if it is a Single-Node cluster
# return 0 if SNO cluster, otherwise 1
function isSNO() {
    local nodes_count
    nodes_count=$(oc get nodes --no-headers | wc -l)
    if (( ${nodes_count} == 1 )); then
        return 0
    else
        return 1
    fi
}

export KUBECONFIG=${SHARED_DIR}/kubeconfig

if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

version=$(oc version -ojson | jq -r '.openshiftVersion' | cut -d. -f 1,2)
echo "OCP version: ${version}"

if ! isIPI; then
    echo "INFO: 'controlplanemachinesets' is not available on UPI cluster, skip."
    exit 0
fi

if isSNO; then
    echo "INFO: 'controlplanemachinesets' is not available on Single-Node cluster, skip."
    exit 0
fi

if ! hasCPMS; then
    echo "INFO: 'controlplanemachinesets' is not supproted (OCP ${version} on ${CLUSTER_TYPE}), skip."
    exit 0
fi

check_result=0

# control-plane machinesets
stderr=$(mktemp)
stdout=$(mktemp)
oc get controlplanemachinesets -n openshift-machine-api --no-headers 1>${stdout} 2>${stderr} || true

echo "control-plane machinesets:"
cat "${stdout}"

curr_state=$(grep cluster ${stdout} | awk '{print $6}' || true)
if [[ "${curr_state}" != "${EXPECTED_CPMS_STATE}" ]]; then
    echo "ERROR: Unexpected controlplanemachinesets state '${curr_state}'."
    echo -e "\n------ STANDARD OUT ------\n$(cat ${stdout})\n------ STANDARD ERROR ------\n$(cat ${stderr})\n"
    exit 1
else
    echo "INFO: controlplanemachinesets does be ${EXPECTED_CPMS_STATE}."
fi

# control-plane machine name check
# Machines
err_output=$(mktemp)
machine_output=$(mktemp)
oc get machines.machine.openshift.io -n openshift-machine-api --selector machine.openshift.io/cluster-api-machine-type=master --no-headers -owide 1>${machine_output} 2>${err_output}

echo "Machines:"
cat "${machine_output}"

if grep -ir 'No resources found in openshift-machine-api namespace.' ${err_output}; then
    echo "ERROR: No machines in openshift-machine-api namespace, but found controlplanemachinesets!"
    check_result=1
fi

control_plane_nodes_count=$(cat "${machine_output}" | wc -l || true)
excepted_count=$(cat "${machine_output}" | awk '{print $1}' | grep -iE "master-[0-9]{1}$" | wc -l || true)

echo "control_plane_nodes_count: ${control_plane_nodes_count}"
echo "excepted_count: ${excepted_count}"

if (( ${excepted_count} < 1 )) || (( ${control_plane_nodes_count} < 1 )); then
    echo "ERROR: control plane nodes count or expected nodes count is less than 1, exit now."
    check_result=1
fi

if [[ "${excepted_count}" != "${control_plane_nodes_count}" ]]; then
    echo "ERROR: One or more control plane machine name is not expected."
    check_result=1
else
    echo "INFO: All control plane machine names are expected."
fi

exit ${check_result}
