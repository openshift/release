#!/bin/bash

# ==============================================================================
# Push Results to OSSM Report Portal via Data Router
#
# This script sends test results from various OpenShift Service Mesh (OSSM) test
# suites to the OSSM Report Portal instance using the Data Router service.
#
# It performs the following steps:
# 1. Validates required environment variables (DATA_ROUTER_USERNAME/PASSWORD)
# 2. Creates a metadata file with test run configuration and attributes
# 3. Sends test results (JUnit XML format) to Report Portal via Data Router
# 4. Cleans up temporary metadata files
#
# Required credentials:
# - Under the path /creds-data-router there should be two files:
#   - username: Data Router username
#   - token: Data Router password/token
# - These files should be mounted via secrets configuration in the CI job
#
# Optional Environment Variables (with defaults):
# - TESTRUN_NAME: Name of the test run (default: "Istio integration test")
# - TESTRUN_DESCRIPTION: Description of the test run
# - ARTIFACT_DIR: Directory containing test artifacts (default: "/tmp/artifacts")
# - TEST_FILE_PATH: Path to JUnit XML test results (default: "${ARTIFACT_DIR}/junit.xml")
# - ISTIO_VERSION: Version of Istio being tested (default: "master")
# - TEST_SUITE: Name of the test suite (default: "sail-e2e-ocp")
# - TEST_REPO: Repository being tested (default: "n/a")
# - INSTALLATION_METHOD: Method used for installation (default: "n/a")
# - EXTRA_ATTRIBUTES: JSON array of additional key/value pairs for metadata
#
# ==============================================================================

set -o nounset
set -o errexit
set -o pipefail

# --- Configuration ---
readonly REPORT_PORTAL_HOSTNAME="reportportal-ossm.apps.dno.ocp-hub.prod.psi.redhat.com"
readonly REPORT_PORTAL_PROJECT="osssm_general"
readonly DATA_ROUTER_URL="https://datarouter.ccitredhat.com"
readonly TESTRUN_NAME=${TESTRUN_NAME:-"Istio integration test"}
readonly TESTRUN_DESCRIPTION=${TESTRUN_DESCRIPTION:-"Istio integration test run for Istio midstream repository"}
readonly STARTTIME=$(date +%s)000
readonly ARTIFACT_DIR=${ARTIFACT_DIR:-"/tmp/artifacts"}
readonly TEST_FILE_PATH=${TEST_FILE_PATH:-"${ARTIFACT_DIR}/junit.xml"}
readonly ISTIO_VERSION=${ISTIO_VERSION:-"master"}
readonly TEST_SUITE=${TEST_SUITE:-"sail-e2e-ocp"}
readonly TEST_REPO=${TEST_REPO:-"n/a"}
readonly INSTALLATION_METHOD=${INSTALLATION_METHOD:-"n/a"}
readonly EXTRA_ATTRIBUTES=${EXTRA_ATTRIBUTES:-""} # JSON array of key/value pairs, e.g. '[{"key": "k1", "value": "v1"}, {"key": "k2", "value": "v2"}]'


# --- Functions ---

create_metadata_file() {
    local metadata_file="metadata.json"

    cat << EOF > "${metadata_file}"
{
    "targets": {
        "reportportal": {
            "config": {
                "hostname": "${REPORT_PORTAL_HOSTNAME}",
                "project": "${REPORT_PORTAL_PROJECT}"
            },
            "processing": {
                "apply_tfa": false,
                "launch": {
                    "name": "${TESTRUN_NAME}",
                    "description": "${TESTRUN_DESCRIPTION}",
                    "startTime": ${STARTTIME},
                    "attributes": [
                        {
                            "key": "tool",
                            "value": "data-router"
                        },
                        {
                            "key": "istio_version",
                            "value": "${ISTIO_VERSION}"
                        },
                        {
                            "key": "stage",
                            "value": "midstream"
                        },
                        {
                            "key": "test_suite",
                            "value": "${TEST_SUITE}"
                        },
                        {
                            "key": "installation_method",
                            "value": "${INSTALLATION_METHOD}"
                        },
                        {
                            "key": "test_repo",
                            "value": "${TEST_REPO}"
                        }
                    ]
                }
            }
        }
    }
}
EOF

    # Check if there are any extra attributes to add
    # The extra attributes are located on the path targets.reportportal.processing.launch.attributes
    if [[ -n "${EXTRA_ATTRIBUTES}" ]]; then
        # Parse the existing attributes and the extra attributes, and merge them
        # This requires 'jq' to be installed
        if ! command -v jq &> /dev/null; then
            echo "ERROR: jq is required to merge extra attributes. Please install jq." >&2
            exit 1
        fi

        local temp_file="metadata_tmp.json"
        if ! jq --argjson extra "${EXTRA_ATTRIBUTES}" '.targets.reportportal.processing.launch.attributes += $extra' "${metadata_file}" > "${temp_file}"; then
            echo "ERROR: Failed to merge extra attributes. Please check EXTRA_ATTRIBUTES format." >&2
            rm -f "${temp_file}"
            exit 1
        fi
        mv "${temp_file}" "${metadata_file}"
    fi
}

send_results() {
    local metadata_file="metadata.json"

    echo "Preparing to send test results from '${TEST_FILE_PATH}'..."

    # Verify test results file exists and is readable
    if [[ ! -f "${TEST_FILE_PATH}" ]]; then
        echo "ERROR: Test results file '${TEST_FILE_PATH}' not found." >&2
        exit 1
    fi

    if [[ ! -r "${TEST_FILE_PATH}" ]]; then
        echo "ERROR: Test results file '${TEST_FILE_PATH}' is not readable." >&2
        exit 1
    fi

    echo "Test results file information:"
    ls -lh "${TEST_FILE_PATH}"

    echo "Creating metadata file..."
    create_metadata_file

    echo "Metadata file created:"
    echo "########################"
    cat "${metadata_file}"
    echo "########################"

    echo "Check data router credentials..."
    # Check if both username and password files exist
    if [[ ! -f /creds-data-router/username || ! -f /creds-data-router/token ]]; then
        echo "ERROR: Data Router credentials files not found in /creds-data-router." >&2
        exit 1
    fi

    DATA_ROUTER_USERNAME=$(cat /creds-data-router/username)
    DATA_ROUTER_PASSWORD=$(cat /creds-data-router/token)
    export DATA_ROUTER_USERNAME
    export DATA_ROUTER_PASSWORD
    if [[ -z "${DATA_ROUTER_USERNAME}" || -z "${DATA_ROUTER_PASSWORD}" ]]; then
        echo "ERROR: Data Router username or password is empty." >&2
        exit 1
    fi
    echo "Data Router credentials found."
    
    echo "Sending test results to Report Portal via Data Router..."
    if ! droute send --metadata "${metadata_file}" \
        --results "${TEST_FILE_PATH}" \
        --username "${DATA_ROUTER_USERNAME}" \
        --password "${DATA_ROUTER_PASSWORD}" \
        --url "${DATA_ROUTER_URL}" \
        --verbose; then
        echo "ERROR: Failed to send results to Data Router." >&2
        rm -f "${metadata_file}"
        exit 1
    fi

    echo "Results sent successfully. Cleaning up metadata file..."
    rm -f "${metadata_file}"
}

# --- Main execution ---
echo "Starting Data Router send step..."
send_results
echo "Data Router send step completed."
exit 0