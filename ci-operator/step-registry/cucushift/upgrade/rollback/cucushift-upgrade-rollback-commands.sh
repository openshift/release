#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'FRC=$?; createUpgradeJunit; debug' EXIT TERM

export HOME="${HOME:-/tmp/home}"
export XDG_RUNTIME_DIR="${HOME}/run"
export REGISTRY_AUTH_PREFERENCE=podman # TODO: remove later, used for migrating oc from docker to podman
mkdir -p "${XDG_RUNTIME_DIR}"
# After cluster is set up, ci-operator make KUBECONFIG pointing to the installed cluster,
# to make "oc registry login" interact with the build farm, set KUBECONFIG to empty,
# so that the credentials of the build farm registry can be saved in docker client config file.
# A direct connection is required while communicating with build-farm, instead of through proxy
KUBECONFIG="" oc --loglevel=8 registry login

# Print cv, failed node, co, mcp information for debug purpose
function debug() {
    if (( FRC != 0 )); then
        echo -e "oc get clusterversion/version -oyaml\n$(oc get clusterversion/version -oyaml)"
        echo -e "oc get machineconfig\n$(oc get machineconfig)"
        echo -e "Describing abnormal nodes...\n"
        oc get node --no-headers | awk '$2 != "Ready" {print $1}' | while read node; do echo -e "\n#####oc describe node ${node}#####\n$(oc describe node ${node})"; done
        echo -e "Describing abnormal operators...\n"
        oc get co --no-headers | awk '$3 != "True" || $4 != "False" || $5 != "False" {print $1}' | while read co; do echo -e "\n#####oc describe co ${co}#####\n$(oc describe co ${co})"; done
        echo -e "Describing abnormal mcp...\n"
        oc get machineconfigpools --no-headers | awk '$3 != "True" || $4 != "False" || $5 != "False" {print $1}' | while read mcp; do echo -e "\n#####oc describe mcp ${mcp}#####\n$(oc describe mcp ${mcp})"; done
    fi
}

# Explicitly set upgrade failure to operators
function check_failed_operator(){
    local latest_ver_in_history failing_status failing_operator failing_operators
    latest_ver_in_history=$(oc get clusterversion version -ojson|jq -r '.status.history[0].version')
    if [[ "${latest_ver_in_history}" != "${TARGET_VERSION}" ]]; then
        # Upgrade does not start, set it to CVO
        echo "Upgrade does not start, set UPGRADE_FAILURE_TYPE to cvo"
        export UPGRADE_FAILURE_TYPE="cvo"
    else
        failing_status=$(oc get clusterversion version -ojson|jq -r '.status.conditions[]|select(.type == "Failing").status')
        # Upgrade stuck at operators while failing=True, check from the operators reported in cv Failing condition
        if [[ ${failing_status} == "True" ]]; then
            failing_operator=$(oc get clusterversion version -ojson|jq -r '.status.conditions[]|select(.type == "Failing").message'|grep -oP 'operator \K.*?(?= is)') || true
            failing_operators=$(oc get clusterversion version -ojson|jq -r '.status.conditions[]|select(.type == "Failing").message'|grep -oP 'operators \K.*?(?= are)'|tr -d ',') || true
            failing_operators="${failing_operator} ${failing_operators}"
        else
            failing_operators=$(oc get clusterversion version -ojson|jq -r '.status.conditions[]|select(.type == "Progressing").message'|grep -oP 'wait has exceeded 40 minutes for these operators: \K.*'|tr -d ',') || \
            failing_operators=$(oc get clusterversion version -ojson|jq -r '.status.conditions[]|select(.type == "Progressing").message'|grep -oP 'waiting up to 40 minutes on \K.*'|tr -d ',') || \
            failing_operators=$(oc get clusterversion version -ojson|jq -r '.status.conditions[]|select(.type == "Progressing").message'|grep -oP 'waiting on \K.*'|tr -d ',') || true
        fi
        if [[ -n "${failing_operators}" && "${failing_operators}" =~ [^[:space:]] ]]; then
            echo "Upgrade stuck, set UPGRADE_FAILURE_TYPE to ${failing_operators}"
            export UPGRADE_FAILURE_TYPE="${failing_operators}"
        fi
    fi
}

# Generate the Junit for upgrade
function createUpgradeJunit() {
    echo -e "\n# Generating the Junit for upgrade"
    local upg_report="${ARTIFACT_DIR}/junit_upgrade.xml"
    local cases_in_upgrade
    if (( FRC == 0 )); then
        # The cases are SLOs on the live cluster which may be a possible UPGRADE_FAILURE_TYPE
        local cases_from_available_operators upgrade_success_cases
        cases_from_available_operators=$(oc get co --no-headers|awk '{print $1}'|tr '\n' ' ' || true)
        upgrade_success_cases="${UPGRADE_FAILURE_TYPE} ${cases_from_available_operators} ${IMPLICIT_ENABLED_CASES}"
        upgrade_success_cases=$(echo ${upgrade_success_cases} | tr ' ' '\n'|sort -u|xargs)
        IFS=" " read -r -a cases_in_upgrade <<< "${upgrade_success_cases}"
        echo '<?xml version="1.0" encoding="UTF-8"?>' > "${upg_report}"
        echo "<testsuite name=\"cluster upgrade\" tests=\"${#cases_in_upgrade[@]}\" failures=\"0\">" >> "${upg_report}"
        for case in "${cases_in_upgrade[@]}"; do
            echo "  <testcase classname=\"cluster upgrade\" name=\"upgrade should succeed: ${case}\"/>" >> "${upg_report}"
        done
        echo '</testsuite>' >> "${upg_report}"
    else
        IFS=" " read -r -a cases_in_upgrade <<< "${UPGRADE_FAILURE_TYPE}"
        echo '<?xml version="1.0" encoding="UTF-8"?>' > "${upg_report}"
        echo "<testsuite name=\"cluster upgrade\" tests=\"${#cases_in_upgrade[@]}\" failures=\"${#cases_in_upgrade[@]}\">" >> "${upg_report}"
        for case in "${cases_in_upgrade[@]}"; do
            echo "  <testcase classname=\"cluster upgrade\" name=\"upgrade should succeed: ${case}\">" >> "${upg_report}"
            echo "    <failure message=\"openshift cluster upgrade failed at ${case}\"></failure>" >> "${upg_report}"
            echo "  </testcase>" >> "${upg_report}"
        done
        echo '</testsuite>' >> "${upg_report}"
    fi
}

function run_command() {
    local CMD="$1"
    echo "Running command: ${CMD}"
    eval "${CMD}"
}

# Rollback the cluster to target release
function rollback() {
    res=$(env "OC_ENABLE_CMD_UPGRADE_ROLLBACK=true" oc adm upgrade rollback 2>&1 || true)
    out="Requested rollback from ${SOURCE_VERSION} to ${TARGET_VERSION}"
    local testcase="OCP-70838"
    export IMPLICIT_ENABLED_CASES="${IMPLICIT_ENABLED_CASES} ${testcase}"
    if [[ ${res} == *"${out}"* ]]; then
        echo "Rolling back cluster from ${SOURCE_VERSION} to ${TARGET_VERSION} started..."
    else
        echo "Rolling back cluster returned unexpected:\n${res}\nexpecting: ${out}"
        # Explicitly set failure to rollback
        export UPGRADE_FAILURE_TYPE="${testcase}"
        return 1
    fi
}

# Monitor the rollback status
function check_rollback_status() {
    local wait_rollback="${TIMEOUT}" out avail progress cluster_version
    cluster_version="${TARGET_VERSION}"
    echo "Starting the rollback checking on $(date "+%F %T")"
    while (( wait_rollback > 0 )); do
        sleep 5m
        wait_rollback=$(( wait_rollback - 5 ))
        if ! ( run_command "oc get clusterversion" ); then
            continue
        fi
        if ! out="$(oc get clusterversion --no-headers || false)"; then
            echo "Error occurred when getting clusterversion"
            continue 
        fi
        avail="$(echo "${out}" | awk '{print $3}')"
        progress="$(echo "${out}" | awk '{print $4}')"
        if [[ ${avail} == "True" && ${progress} == "False" && ${out} == *"Cluster version is ${cluster_version}" ]]; then
            echo -e "Rollback succeed on $(date "+%F %T")\n\n"
            return 0
        fi
    done
    if [[ ${wait_rollback} -le 0 ]]; then
        echo -e "Rollback timeout on $(date "+%F %T"), exiting\n"
        check_failed_operator
        return 1
    fi
}

# Check version, state in history
function check_history() {
    local version state testcase="OCP-70838"
    version=$(oc get clusterversion/version -o jsonpath='{.status.history[0].version}')
    state=$(oc get clusterversion/version -o jsonpath='{.status.history[0].state}')
    export IMPLICIT_ENABLED_CASES="${IMPLICIT_ENABLED_CASES} ${testcase}"
    if [[ ${version} == "${TARGET_VERSION}" && ${state} == "Completed" ]]; then
        echo "History check PASSED, cluster is now rollbacked to ${TARGET_VERSION}" && return 0
    else
        echo >&2 "History check FAILED, cluster rollbacked to ${TARGET_VERSION} failed, current version is ${version}, state is ${state}, exiting"
	# Explicitly set failure to cvo
	export UPGRADE_FAILURE_TYPE="${testcase}"
	return 1
    fi
}

if [[ -f "${SHARED_DIR}/kubeconfig" ]] ; then
    export KUBECONFIG=${SHARED_DIR}/kubeconfig
fi

# Setup proxy if it's present in the shared dir
if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
    # shellcheck disable=SC1091
    source "${SHARED_DIR}/proxy-conf.sh"
fi

run_command "oc get machineconfig"

export TARGET="${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}"
TARGET_VERSION="$(env "NO_PROXY=*" "no_proxy=*" oc adm release info "${TARGET}" --output=json | jq -r '.metadata.version')"

SOURCE_VERSION="$(oc get clusterversion --no-headers | awk '{print $2}')"
export SOURCE_VERSION
echo -e "Source release version is: ${SOURCE_VERSION}"

export TARGET_VERSION
echo -e "Target release version is: ${TARGET_VERSION}"
# Set genenral upgrade ci failure to overall as default
export UPGRADE_FAILURE_TYPE="overall"
# The cases are from existing general checkpoints enabled implicitly in upgrade step, which may be a possible UPGRADE_FAILURE_TYPE
export IMPLICIT_ENABLED_CASES=""

rollback
check_rollback_status
check_history
