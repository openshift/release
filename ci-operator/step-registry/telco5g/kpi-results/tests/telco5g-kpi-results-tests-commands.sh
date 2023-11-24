#!/bin/bash

set -o nounset
set -o pipefail

# Constants for the server used to save reports
KPI_RESULTS_SERVER="http://ocp-far-edge-vran-deployment-kpi.hosts.prod.psi.rdu2.redhat.com"
KPI_RESULTS_BASE_API="/backend/api/v1/reports/"

# Temporary file used to save the report data
KPI_RESULTS_FILE_PATH="/tmp/kpi-results.json"

function get_date_stamp() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')]"
}

function print_error() {
    # msg will be passed as an argument to the function
    local msg
    msg=$1

    # write the error to stderr
    echo "$(get_date_stamp) [ERROR] ${msg}" >&2
}

function print_message() {
    # msg will be passed as an argument to the function
    local msg
    msg=$1

    # write the message to stdout
    echo "$(get_date_stamp) [INFO] ${msg}"
}

function cleanup() {
    # Check if the kpi results file exists
    if [[ -f "${KPI_RESULTS_FILE_PATH}" ]]; then
        # Delete it if it exists
        rm "${KPI_RESULTS_FILE_PATH}"
    fi
}

function download_kpi_results_report() {
    # ocp version will be passed as an argument to the function
    local ocp_version
    ocp_version=$1

    # url filters will be generated using the provided version
    local api_filters
    api_filters="?max_results=1&start_version=${ocp_version}&end_version=${ocp_version}&description=KPI"

    # Build the url
    local url
    url="${KPI_RESULTS_SERVER}${KPI_RESULTS_BASE_API}${api_filters}"

    # Print the url
    print_message "Downloading data report from url: '${url}'"

    # fetch the report from the server using curl
    curl -s "${url}" 2>/dev/null 1>${KPI_RESULTS_FILE_PATH}
}

function did_specified_test_pass() {
    # the test name will be passed as an argument to the function   
    local test_name
    test_name=$1

    # build the jq filter based on the test name
    local jq_filter
    jq_filter=".[0].json_data | fromjson | .testsuites |  .[] | select(.testsuite | test(\"$test_name\")) | .tests[].result.status"

    # get the test result from the file
    local result
    result=$(jq "${jq_filter}" "${KPI_RESULTS_FILE_PATH}" | sed 's/"//g')

    # Print what we are checking
    print_message "Checking status of result for test '${test_name}'"

    # if the result is not success then return an error
    if ! [[ "${result}" == "pass" ]]; then
        # Print what we are checking
        print_error "Test '${test_name}' failed"
        return 1
    fi

    # Print what we are checking
    print_message "Test '${test_name}' passed"

    # if the result was success then return 0
    return 0
}

function get_test_result_data() {
    # check if the file exists
    print_message "Check if file '${KPI_RESULTS_FILE_PATH}' exists"

    if ! [[ -f "${KPI_RESULTS_FILE_PATH}" ]]; then
        print_error "File '${KPI_RESULTS_FILE_PATH}' does not exist"
        return 16
    fi

    # check if the file is empty
    print_message "Check if file '${KPI_RESULTS_FILE_PATH}' is empty"
    if ! [[ -s "${KPI_RESULTS_FILE_PATH}" ]]; then
        print_error "File '${KPI_RESULTS_FILE_PATH}' is empty"
        return 8
    fi

    # check if the file is json parsable
    print_message "Check if file '${KPI_RESULTS_FILE_PATH}' contains valid json"

    local json_check
    json_check="$(jq -e 'select(length > 0)' ${KPI_RESULTS_FILE_PATH} >/dev/null && echo true)"
    if ! [[ "${json_check}" == "true" ]]; then
        print_error "File '${KPI_RESULTS_FILE_PATH}' does not contain valid json"
        return 4
    fi

    # get the report uuid for diagnostic purposes
    print_message "Checking tests from report '$(jq .[0].uuid ${KPI_RESULTS_FILE_PATH} | sed 's/\"//g')'"

    # temporary storage for error states
    local result
    result=0

    # Check if oslat test data is present
    local oslat_result
    did_specified_test_pass 'oslat'
    oslat_result=$?

    # check if oslat passed
    if [[ "${oslat_result}" -gt 0 ]]; then
        result=$((result + 2))
    fi

    # Check is cyclictest test data is present
    local cyclictest_result
    did_specified_test_pass 'cyclictest'
    cyclictest_result=$?

    # check if cyclictest passed
    if [[ "${cyclictest_result}" -gt 0 ]]; then
        result=$((result + 1))
    fi

    # the returned result here can be mapped to a bit error state
    # rc 00 (00000) - oslat and cyclictest both passed
    # rc 01 (00001) - cyclictest failed criteria
    # rc 02 (00010) - oslat failed criteria
    # rc 03 (00011) - oslat and cyclictest both failed criteria
    # rc 04 (00100) - kpi results file found but not valid json
    # rc 08 (01000) - kpi results file found but is an empty file
    # rc 16 (10000) - kpi results file not found
    return "${result}"
}

function main(){
    # set trap for cleanup on exit
    trap cleanup EXIT

    # make sure file doesn't already exist
    cleanup

    # check if $OCP_RELEASE_VERSION is defined
    if [[ -z "${OCP_RELEASE_VERSION}" ]]; then
        print_error "Environment variable \$OCP_RELEASE_VERSION was not defined"
        exit 32
    fi

    # download the report
    download_kpi_results_report "${OCP_RELEASE_VERSION}"

    # Check the test data
    local test_data
    get_test_result_data
    test_data=$?

    if [[ "${test_data}" -eq 0 ]]; then
        print_message "Cyclictest and Oslat both passed criteria"
    fi

    # exit using the provided status code
    exit "${test_data}"
}

echo $RELEASE_IMAGE_INITIAL
echo $RELEASE_IMAGE_LATEST
main
