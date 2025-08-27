#!/bin/bash
# script to create prowjobs in ci-operator/config/openshift/sandboxed-containers-operator using environment variables.
# Usage: ./sandboxed-containers-operator-create-prowjob-commands.sh
# should be run in a branch of a fork of https://github.com/openshift/release/

# created with the assistance of Cursor AI

set -o nounset
set -o errexit
set -o pipefail

# Function to get latest OSC catalog tag
get_latest_osc_catalog_tag() {
    local apiurl="https://quay.io/api/v1/repository/redhat-user-workloads/ose-osc-tenant/osc-test-fbc"
    local page=1
    local max_pages=20
    local test_pattern="^[0-9]+\.[0-9]+(\.[0-9]+)?-[0-9]+$"
    local latest_tag=""

    while [[ ${page} -le ${max_pages} ]]; do
        local resp
        if ! resp=$(curl -sf "${apiurl}/tag/?limit=100&page=${page}"); then
            break
        fi

        if ! jq -e '.tags | length > 0' <<< "${resp}" >/dev/null; then
            break
        fi

        latest_tag=$(echo "${resp}" | \
            jq -r --arg test_string "${test_pattern}" \
            '.tags[]? | select(.name | test($test_string)) | "\(.start_ts) \(.name)"' | \
            sort -nr | head -n1 | awk '{print $2}')

        if [[ -n "${latest_tag}" ]]; then
            break
        fi

        ((page++))
    done

    if [[ -z "${latest_tag}" ]]; then
        echo "  ERROR: No matching OSC catalog tag found, using default fallback"
        exit 1
        latest_tag="1.10.1-1755502791"
    fi

    echo "${latest_tag}"
}

get_latest_trustee_catalog_tag() {
    local page=1
    local latest_tag=""
    local test_pattern="^trustee-fbc-${OCP_VER}-on-push-.*-build-image-index$"

    while true; do
        local resp

        # Query the Quay API for tags
        if ! resp=$(curl -sf "${APIURL}/tag/?limit=100&page=${page}"); then
            break
        fi

        # Check if page has tags
        if ! jq -e '.tags | length > 0' <<< "${resp}" >/dev/null; then
            break
        fi

        # Extract the latest matching tag from this page
        latest_tag=$(echo "${resp}" | \
            jq -r --arg test_string "${test_pattern}" \
            '.tags[]? | select(.name | test($test_string)) | "\(.start_ts) \(.name)"' | \
            sort -nr | head -n1 | awk '{print $2}')

        if [[ -n "${latest_tag}" ]]; then
            break
        fi

        ((page++))


        # Safety limit to prevent infinite loops
        if [[ ${page} -gt 50 ]]; then
            echo "ERROR: Reached maximum page limit (50) while searching for tags"
            exit 1
            break
        fi
    done

    echo "${latest_tag}"
}

echo "=========================================="
echo "Sandboxed Containers Operator - Prowjob Configuration Generator"


# Validate required parameters and set defaults
echo "Validating parameters and setting defaults..."

# OCP version to test
OCP_VERSION="${OCP_VERSION:-4.19}"
# Validate OCP version format
if [[ ! "${OCP_VERSION}" =~ ^[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: Invalid OCP_VERSION format. Expected format: X.Y (e.g., 4.19)"
    exit 1
fi

# AWS Region Configuration
AWS_REGION_OVERRIDE="${AWS_REGION_OVERRIDE:-us-east-2}"

# Azure Region Configuration
CUSTOM_AZURE_REGION="${CUSTOM_AZURE_REGION:-eastus}"

# OSC Version Configuration
EXPECTED_OSC_VERSION="${EXPECTED_OSC_VERSION:-1.10.1}"

# Kata RPM Configuration
INSTALL_KATA_RPM="${INSTALL_KATA_RPM:-true}"
if [[ "${INSTALL_KATA_RPM}" != "true" && "${INSTALL_KATA_RPM}" != "false" ]]; then
    echo "ERROR: INSTALL_KATA_RPM should be 'true' or 'false', got: ${INSTALL_KATA_RPM}"
    exit 1
fi

# Kata RPM version (includes OCP version)
if [[ "${INSTALL_KATA_RPM}" == "true" ]]; then
    KATA_RPM_VERSION="${KATA_RPM_VERSION:-3.17.0-3.rhaos4.19.el9}"
else
    KATA_RPM_VERSION="${KATA_RPM_VERSION:-}"
fi

# Prow Configuration
PROW_RUN_TYPE="${PROW_RUN_TYPE:-candidate}"
# Validate PROW_RUN_TYPE
if [[ "${PROW_RUN_TYPE}" != "candidate" && "${PROW_RUN_TYPE}" != "release" ]]; then
    echo "ERROR: PROW_RUN_TYPE should be 'candidate' or 'release', got: ${PROW_RUN_TYPE}"
    exit 1
fi

# After the tests finish, wait before killing the cluster
SLEEP_DURATION="${SLEEP_DURATION:-0h}"
# Validate SLEEP_DURATION format (0-12 followed by 'h')
if ! [[ "${SLEEP_DURATION}" =~ ^(1[0-2]|[0-9])h$ ]]; then
    echo "ERROR: SLEEP_DURATION must be a number between 0-12 followed by 'h' (e.g., 2h, 8h), got: ${SLEEP_DURATION}"
    exit 1
fi

# test is Pre-GA for brew builds or GA for operators/rpms already on OCP
# this triggers the mirror redirect install, creating brew & trustee catsrc,
TEST_RELEASE_TYPE="${TEST_RELEASE_TYPE:-Pre-GA}"
# Validate TEST_RELEASE_TYPE
if [[ "${TEST_RELEASE_TYPE}" != "Pre-GA" && "${TEST_RELEASE_TYPE}" != "GA" ]]; then
    echo "ERROR: TEST_RELEASE_TYPE should be 'Pre-GA' or 'GA', got: ${TEST_RELEASE_TYPE}"
    exit 1
fi

# Let the tests run for this many minutes before killing the cluster and interupting the test
TEST_TIMEOUT="${TEST_TIMEOUT:-90}"
# Validate TEST_TIMEOUT is numeric
if ! [[ "${TEST_TIMEOUT}" =~ ^[0-9]+$ ]]; then
    echo "ERROR: TEST_TIMEOUT should be numeric, got: ${TEST_TIMEOUT}"
    exit 1
fi



# Catalog Source Configuration
echo "Configuring catalog sources..."

# Set catalog source variables based on TEST_RELEASE_TYPE
if [[ "${TEST_RELEASE_TYPE}" == "Pre-GA" ]]; then
    # OSC Catalog Configuration - get latest or use provided
    if [[ -z "${OSC_CATALOG_TAG:-}" ]]; then
        OSC_CATALOG_TAG=$(get_latest_osc_catalog_tag)
    else
        echo "Using provided OSC_CATALOG_TAG: ${OSC_CATALOG_TAG}"
    fi

    CATALOG_SOURCE_IMAGE="${CATALOG_SOURCE_IMAGE:-quay.io/redhat-user-workloads/ose-osc-tenant/osc-test-fbc:${OSC_CATALOG_TAG}}"
    CATALOG_SOURCE_NAME="${CATALOG_SOURCE_NAME:-brew-catalog}"

    # Trustee Catalog Configuration
    # Convert OCP version for Trustee catalog naming
    OCP_VER=$(echo "${OCP_VERSION}" | tr '.' '-')
    subfolder=""
    if [[ "${OCP_VER}" == "4-16" ]]; then
        subfolder="trustee-fbc/"
    fi
    # Get latest Trustee catalog tag with page limit safety
    TRUSTEE_REPO_NAME="${subfolder}trustee-fbc-${OCP_VER}"
    TRUSTEE_CATALOG_REPO="quay.io/redhat-user-workloads/ose-osc-tenant/${TRUSTEE_REPO_NAME}"

    APIURL="https://quay.io/api/v1/repository/redhat-user-workloads/ose-osc-tenant/${TRUSTEE_REPO_NAME}"
    TRUSTEE_CATALOG_TAG=$(get_latest_trustee_catalog_tag)

    TRUSTEE_CATALOG_SOURCE_IMAGE="${TRUSTEE_CATALOG_SOURCE_IMAGE:-${TRUSTEE_CATALOG_REPO}:${TRUSTEE_CATALOG_TAG}}"
    TRUSTEE_CATALOG_SOURCE_NAME="${TRUSTEE_CATALOG_SOURCE_NAME:-trustee-catalog}"
else # GA
    CATALOG_SOURCE_NAME="${CATALOG_SOURCE_NAME:-redhat-operators}"
    TRUSTEE_CATALOG_SOURCE_NAME="${TRUSTEE_CATALOG_SOURCE_NAME:-redhat-operators}"
fi

# Generate output file path
OCP_PROWJOB_VERSION=$(echo "${OCP_VERSION}" | tr -d '.' )
OUTPUT_FILE="openshift-sandboxed-containers-operator-devel__downstream-${PROW_RUN_TYPE}${OCP_PROWJOB_VERSION}.yaml"
echo "Generating prowjob configuration..."

# Backup existing file if it exists
if [[ -f "${OUTPUT_FILE}" ]]; then
    echo "Backing up existing file: ${OUTPUT_FILE}.backup"
    cp "${OUTPUT_FILE}" "${OUTPUT_FILE}.backup"
fi

# Generate the prowjob configuration file

cat > "${OUTPUT_FILE}" <<EOF
documentation: |-
  DO NOT EDIT DIRECTLY.
  This is generated by the sandboxed-containers-operator-create-prowjob-commands.sh script.
base_images:
  tests-private:
    name: tests-private
    namespace: ci
    tag: "4.20"
  upi-installer:
    name: "${OCP_VERSION}"
    namespace: ocp
    tag: upi-installer
releases:
  latest:
    release:
      architecture: amd64
      channel: stable
      version: "${OCP_VERSION}"
resources:
  '*':
    requests:
      cpu: 100m
      memory: 200Mi
tests:
- as: azure-ipi-kata
  cron: 0 0 31 2 1
  steps:
    cluster_profile: azure-qe
    env:
      CUSTOM_AZURE_REGION: ${CUSTOM_AZURE_REGION}
      BASE_DOMAIN: qe.azure.devcluster.openshift.com
      CATALOG_SOURCE_IMAGE: ${CATALOG_SOURCE_IMAGE}
      CATALOG_SOURCE_NAME: ${CATALOG_SOURCE_NAME}
      EXPECTED_OPERATOR_VERSION: ${EXPECTED_OSC_VERSION}
      INSTALL_KATA_RPM: ${INSTALL_KATA_RPM}
      KATA_RPM_VERSION: ${KATA_RPM_VERSION}
      SLEEP_DURATION: ${SLEEP_DURATION}
      TEST_FILTERS: ~DisconnectedOnly&;~Disruptive&
      TEST_RELEASE_TYPE: ${TEST_RELEASE_TYPE}
      TEST_SCENARIOS: sig-kata.*Kata Author
      TEST_TIMEOUT: "${TEST_TIMEOUT}"
      TRUSTEE_CATALOG_SOURCE_IMAGE: ${TRUSTEE_CATALOG_SOURCE_IMAGE}
      TRUSTEE_CATALOG_SOURCE_NAME: ${TRUSTEE_CATALOG_SOURCE_NAME}
    workflow: sandboxed-containers-operator-e2e-azure
- as: azure-ipi-peerpods
  cron: 0 0 31 2 1
  steps:
    cluster_profile: azure-qe
    env:
      BASE_DOMAIN: qe.azure.devcluster.openshift.com
      CATALOG_SOURCE_IMAGE: ${CATALOG_SOURCE_IMAGE}
      CATALOG_SOURCE_NAME: ${CATALOG_SOURCE_NAME}
      CUSTOM_AZURE_REGION: ${CUSTOM_AZURE_REGION}
      ENABLEPEERPODS: "true"
      EXPECTED_OPERATOR_VERSION: ${EXPECTED_OSC_VERSION}
      INSTALL_KATA_RPM: ${INSTALL_KATA_RPM}
      KATA_RPM_VERSION: ${KATA_RPM_VERSION}
      RUNTIMECLASS: kata-remote
      SLEEP_DURATION: ${SLEEP_DURATION}
      TEST_FILTERS: ~DisconnectedOnly&;~Disruptive&
      TEST_RELEASE_TYPE: ${TEST_RELEASE_TYPE}
      TEST_SCENARIOS: sig-kata.*Kata Author
      TEST_TIMEOUT: "${TEST_TIMEOUT}"
      TRUSTEE_CATALOG_SOURCE_IMAGE: ${TRUSTEE_CATALOG_SOURCE_IMAGE}
      TRUSTEE_CATALOG_SOURCE_NAME: ${TRUSTEE_CATALOG_SOURCE_NAME}
      WORKLOAD_TO_TEST: peer-pods
    workflow: sandboxed-containers-operator-e2e-azure
- as: azure-ipi-coco
  cron: 0 0 31 2 1
  steps:
    cluster_profile: azure-qe
    env:
      BASE_DOMAIN: qe.azure.devcluster.openshift.com
      CATALOG_SOURCE_IMAGE: ${CATALOG_SOURCE_IMAGE}
      CATALOG_SOURCE_NAME: ${CATALOG_SOURCE_NAME}
      CUSTOM_AZURE_REGION: ${CUSTOM_AZURE_REGION}
      ENABLEPEERPODS: "true"
      EXPECTED_OPERATOR_VERSION: ${EXPECTED_OSC_VERSION}
      INSTALL_KATA_RPM: ${INSTALL_KATA_RPM}
      KATA_RPM_VERSION: ${KATA_RPM_VERSION}
      RUNTIMECLASS: kata-remote
      SLEEP_DURATION: ${SLEEP_DURATION}
      TEST_FILTERS: ~DisconnectedOnly&;~Disruptive&
      TEST_RELEASE_TYPE: ${TEST_RELEASE_TYPE}
      TEST_SCENARIOS: sig-kata.*Kata Author
      TEST_TIMEOUT: "${TEST_TIMEOUT}"
      TRUSTEE_CATALOG_SOURCE_IMAGE: ${TRUSTEE_CATALOG_SOURCE_IMAGE}
      TRUSTEE_CATALOG_SOURCE_NAME: ${TRUSTEE_CATALOG_SOURCE_NAME}
      WORKLOAD_TO_TEST: coco
    workflow: sandboxed-containers-operator-e2e-azure
- as: aws-ipi-peerpods
  cron: 0 0 31 2 1
  steps:
    cluster_profile: aws
    env:
      AWS_REGION_OVERRIDE: ${AWS_REGION_OVERRIDE}
      CATALOG_SOURCE_IMAGE: ${CATALOG_SOURCE_IMAGE}
      CATALOG_SOURCE_NAME: ${CATALOG_SOURCE_NAME}
      ENABLEPEERPODS: "true"
      EXPECTED_OPERATOR_VERSION: ${EXPECTED_OSC_VERSION}
      INSTALL_KATA_RPM: ${INSTALL_KATA_RPM}
      KATA_RPM_VERSION: ${KATA_RPM_VERSION}
      RUNTIMECLASS: kata-remote
      SLEEP_DURATION: ${SLEEP_DURATION}
      TEST_FILTERS: ~DisconnectedOnly&;~Disruptive&
      TEST_RELEASE_TYPE: ${TEST_RELEASE_TYPE}
      TEST_SCENARIOS: sig-kata.*Kata Author
      TEST_TIMEOUT: "${TEST_TIMEOUT}"
      TRUSTEE_CATALOG_SOURCE_IMAGE: ${TRUSTEE_CATALOG_SOURCE_IMAGE}
      TRUSTEE_CATALOG_SOURCE_NAME: ${TRUSTEE_CATALOG_SOURCE_NAME}
      WORKLOAD_TO_TEST: peer-pods
    workflow: sandboxed-containers-operator-e2e-aws
- as: aws-ipi-coco
  cron: 0 0 31 2 1
  steps:
    cluster_profile: aws
    env:
      AWS_REGION_OVERRIDE: ${AWS_REGION_OVERRIDE}
      CATALOG_SOURCE_IMAGE: ${CATALOG_SOURCE_IMAGE}
      CATALOG_SOURCE_NAME: ${CATALOG_SOURCE_NAME}
      ENABLEPEERPODS: "true"
      EXPECTED_OPERATOR_VERSION: ${EXPECTED_OSC_VERSION}
      INSTALL_KATA_RPM: ${INSTALL_KATA_RPM}
      KATA_RPM_VERSION: ${KATA_RPM_VERSION}
      RUNTIMECLASS: kata-remote
      SLEEP_DURATION: ${SLEEP_DURATION}
      TEST_FILTERS: ~DisconnectedOnly&;~Disruptive&
      TEST_RELEASE_TYPE: ${TEST_RELEASE_TYPE}
      TEST_SCENARIOS: sig-kata.*Kata Author
      TEST_TIMEOUT: "${TEST_TIMEOUT}"
      TRUSTEE_CATALOG_SOURCE_IMAGE: ${TRUSTEE_CATALOG_SOURCE_IMAGE}
      TRUSTEE_CATALOG_SOURCE_NAME: ${TRUSTEE_CATALOG_SOURCE_NAME}
      WORKLOAD_TO_TEST: coco
    workflow: sandboxed-containers-operator-e2e-aws
zz_generated_metadata:
  branch: devel
  org: openshift
  repo: sandboxed-containers-operator
  variant: downstream-${PROW_RUN_TYPE}
EOF

# Validate the generated file
echo "Validating generated configuration..."

if [[ ! -f "${OUTPUT_FILE}" ]]; then
    echo "ERROR: Failed to create output file: ${OUTPUT_FILE}"
    exit 1
fi

# Check file size
file_size=$(wc -c < "${OUTPUT_FILE}")
if [[ ${file_size} -lt 1000 ]]; then
    echo "WARNING: Generated file seems too small (${file_size} bytes)"
fi

# Basic YAML syntax validation if yq is available
if command -v yq &> /dev/null; then
    echo "Validating YAML syntax with yq..."
    if yq eval '.' "${OUTPUT_FILE}" >/dev/null 2>&1; then
        echo "✓ YAML syntax is valid"
    else
        echo "✗ YAML syntax validation failed"
        exit 1
    fi
else
    echo "INFO: yq not available, skipping YAML syntax validation"
fi

# Show configuration summary
echo "=========================================="
echo "Configuration details:"
echo "  • OCP Version: ${OCP_VERSION}"
echo "  • Prow Run Type: ${PROW_RUN_TYPE}"
echo "  • Test Release Type: ${TEST_RELEASE_TYPE}"
echo "  • Expected OSC Version: ${EXPECTED_OSC_VERSION}"
echo "  • AWS Region: ${AWS_REGION_OVERRIDE}"
echo "  • Azure Region: ${CUSTOM_AZURE_REGION}"
echo "  • Kata RPM: ${INSTALL_KATA_RPM} (${KATA_RPM_VERSION})"
echo "  • Sleep Duration: ${SLEEP_DURATION}"
echo "  • Test Timeout: ${TEST_TIMEOUT}"

if [[ "${TEST_RELEASE_TYPE}" == "Pre-GA" ]]; then
    echo "  • Catalog Source: ${CATALOG_SOURCE_NAME} (${CATALOG_SOURCE_IMAGE})"
    echo "  • Trustee Catalog: ${TRUSTEE_CATALOG_SOURCE_NAME} (${TRUSTEE_CATALOG_SOURCE_IMAGE})"
else
    echo "  • Catalog Source: ${CATALOG_SOURCE_NAME}"
    echo "  • Trustee Catalog: ${TRUSTEE_CATALOG_SOURCE_NAME}"
fi

echo "=========================================="
echo "Generated file: ${OUTPUT_FILE}"
echo "File size: ${file_size} bytes"
echo "=========================================="
echo "Next Steps:"
echo "1. Review the generated configuration file:"
echo "   cat ${OUTPUT_FILE}"
echo ""
echo "2. Move it to the appropriate directory:"
echo "   mv ${OUTPUT_FILE} ci-operator/config/openshift/sandboxed-containers-operator/"
echo ""
echo "3. Generate and update CI configuration before creating PR:"
echo "   make ci-operator-config && make prow-config && make jobs && make update"
echo ""
