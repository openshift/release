#!/bin/bash

set -o nounset
set -o pipefail

# Constants for the server used to save reports
KPI_RESULTS_SERVER="https://10.0.12.113"
KPI_RESULTS_BASE_API="/backend/api/v1/reports/"

# Temporary file used to save the report data
KPI_RESULTS_FILE_PATH="/tmp/kpi-results.json"

# Temporary path used for jq binary
JQ_FILE_PATH="/tmp/jq"

# Default value for description
KPI_DESCRIPTION="${KPI_DESCRIPTION:-KPI}"

# The official graph contains the mappings for all hashes to version strings
OCP_UPGRADE_GRAPH_URL="${OCP_UPGRADE_GRAPH_URL:-https://amd64.ocp.releases.ci.openshift.org/graph}"

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

function get_version_string_for_image_hash() {
    # The full image digest is passed as $1
    local image_digest
    image_digest=$1

    # Get just the hash as the part after the colon
    local image_hash
    image_hash=$(echo "${image_digest}" | awk -F':' '{print $2}')

    # Get the version from the graph
    local version
    version=$(curl "${OCP_UPGRADE_GRAPH_URL}" | \
        ${JQ_FILE_PATH} ".nodes[] | select (.payload | contains(\"${image_hash}\")) .version")

    # Return the version but also remove any extra quotes around it
    echo "${version}" | sed 's/"//g' | sed "s/'//g"
}

function download_jq() {
    # Check if jq is on path first
    local jq_path
    jq_path=$(which jq 2> /dev/null || echo "")

    # If not found, then download it
    if [[ -z "${jq_path}" ]]; then
        print_message "Downloading jq to '${JQ_FILE_PATH}'"
        # Download jq from github
        curl -sfL https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 -o "${JQ_FILE_PATH}"
        # Set executable
        chmod a+x "${JQ_FILE_PATH}"
    else
        # If found then use it
        print_message "Using jq from path '${jq_path}'"
        JQ_FILE_PATH="${jq_path}"
    fi
}

function download_kpi_results_report() {
    # ocp version will be passed as an argument to the function
    local ocp_version
    ocp_version=$1

    # kpi description will be used in the url
    local kpi_description
    kpi_description=$2

    # replace any spaces in the description with url encoded %20 characters for the api call
    kpi_description="$(echo "${kpi_description}" | sed 's/\s/%20/g')"

    # url filters will be generated using the provided version
    local api_filters
    api_filters="?max_results=1&start_version=${ocp_version}&end_version=${ocp_version}&description=${kpi_description}"

    # Build the url
    local url
    url="${KPI_RESULTS_SERVER}${KPI_RESULTS_BASE_API}${api_filters}"

    # Print the url
    print_message "Downloading data report from url: '${url}'"

    # fetch the report from the server using curl
    curl -k "${url}" -o ${KPI_RESULTS_FILE_PATH}
}

function did_specified_test_pass() {
    # the test name will be passed as an argument to the function   
    local test_name
    test_name=$1

    # build the jq filter based on the test name
    local jq_filter
    jq_filter=".[0].json_data | fromjson | .testsuites |  .[] | select(.testsuite | test(\"$test_name\")) | .tests[].result.status"

    # get the test results from the file
    local results
    mapfile -t results < <(${JQ_FILE_PATH} "${jq_filter}" "${KPI_RESULTS_FILE_PATH}" | sed 's/"//g')

    # Print what we are checking
    print_message "Checking status of result for test '${test_name}'"

    # there should be 3 results for each
    # we need all 3 to pass
    local result
    for result in "${results[@]}"; do
        # if the result is not success then return an error
        if ! [[ "${result}" == "pass" ]]; then
            # Print what we are checking
            print_error "Test '${test_name}' failed"
            return 1
        fi
    done

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
    json_check="$(${JQ_FILE_PATH} -e 'select(length > 0)' ${KPI_RESULTS_FILE_PATH} >/dev/null && echo true)"
    if ! [[ "${json_check}" == "true" ]]; then
        print_error "File '${KPI_RESULTS_FILE_PATH}' does not contain valid json"
        return 4
    fi

    # get the report uuid for diagnostic purposes
    print_message "Checking tests from report '$(${JQ_FILE_PATH} .[0].uuid ${KPI_RESULTS_FILE_PATH} | sed 's/\"//g')'"

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

function main() {
    # set trap for cleanup on exit
    trap cleanup EXIT

    # make sure file doesn't already exist
    cleanup

    # Check for jq
    download_jq

    # check if $RELEASE_IMAGE_LATEST is defined
    if [[ -z "${RELEASE_IMAGE_LATEST}" ]]; then
        print_error "Environment variable \$RELEASE_IMAGE_LATEST was not defined"
        exit 64
    fi

    print_message "Resolving digests using graph: '${OCP_UPGRADE_GRAPH_URL}'"
    print_message "Fetching version for digest:  '${RELEASE_IMAGE_LATEST}'"

    # Get the ocp release from environment
    # These are passed automatically from the ci-operator
    # See docs for more information:
    # https://docs.ci.openshift.org/docs/architecture/ci-operator/#testing-with-an-existing-openshift-release
    # When doing this, an image digest is passed instead of a version string
    # We have to get the version string ourself from the upgrade graph
    OCP_RELEASE_VERSION="$(get_version_string_for_image_hash "${RELEASE_IMAGE_LATEST}")"

    # check if $OCP_RELEASE_VERSION is defined
    if [[ -z "${OCP_RELEASE_VERSION}" ]]; then
        print_error "Failed to get version string for image ${RELEASE_IMAGE_LATEST}"
        exit 32
    fi

    print_message "Got version string '${OCP_RELEASE_VERSION}' for digest"

    # download the report
    download_kpi_results_report "${OCP_RELEASE_VERSION}" "${KPI_DESCRIPTION}"

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

main
