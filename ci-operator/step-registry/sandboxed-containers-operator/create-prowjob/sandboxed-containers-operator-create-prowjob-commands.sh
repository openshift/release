#!/bin/bash
# script to create prowjobs in ci-operator/config/openshift/sandboxed-containers-operator using environment variables.
# Usage:
#   ./sandboxed-containers-operator-create-prowjob-commands.sh gen    # Generate prowjob configuration
#   ./sandboxed-containers-operator-create-prowjob-commands.sh run    # Run prowjobs
# should be run in a branch of a fork of https://github.com/openshift/release/

# created with the assistance of Cursor AI

set -o nounset
set -o errexit
set -o pipefail

# Endpoint for the Gangway API (https://docs.prow.k8s.io/docs/components/optional/gangway/)
# used to interact with Prow via REST API
GANGWAY_API_ENDPOINT="https://gangway-ci.apps.ci.l2s4.p1.openshiftapps.com/v1/executions"
ARO_CLUSTER_VERSION="${ARO_CLUSTER_VERSION:-4.17}"

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
        latest_tag="latest"
    fi

    echo "${latest_tag}"
}

get_expected_version() {
    # Extract expected version from catalog tag
    # If catalog tag is in X.Y.Z-[0-9]+ format, returns X.Y.Z portion
    # If input is "latest", returns "0.0.0"
    # Otherwise returns empty string
    local catalog_tag="$1"

    if [[ "${catalog_tag}" =~ ^([0-9]+\.[0-9]+\.[0-9]+)-[0-9]+$ ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ "${catalog_tag}" == "latest" ]]; then
        echo "0.0.0"
    else
        echo ""
    fi
}
# Function to check if a specific version exists in an OCP release channel
# Uses the Cincinnati API to query available versions
check_version_in_channel() {
    local version="$1"
    local channel="$2"
    local major_minor

    # Extract major.minor from version (e.g., 4.18 from 4.18.30)
    major_minor=$(echo "${version}" | cut -d'.' -f1,2)

    # Cincinnati API endpoint
    local api_url="https://api.openshift.com/api/upgrades_info/v1/graph?channel=${channel}-${major_minor}&arch=amd64"

    echo "Checking if version ${version} exists in ${channel}-${major_minor} channel..."

    # Query the API and check if version exists
    local response
    if ! response=$(curl -sf "${api_url}" 2>/dev/null); then
        echo "WARNING: Unable to query Cincinnati API. Skipping version check."
        echo "  URL: ${api_url}"
        return 0
    fi

    # Check if the version exists in the response
    if echo "${response}" | jq -e --arg ver "${version}" '.nodes[] | select(.version == $ver)' >/dev/null 2>&1; then
        echo "✓ Version ${version} found in ${channel}-${major_minor} channel"
        return 0
    else
        echo "ERROR: Version ${version} not found in ${channel}-${major_minor} channel"
        echo ""
        echo "5 newest versions in ${channel}-${major_minor} (newest first):"
        echo "${response}" | jq -r '.nodes[].version' 2>/dev/null | sort -rV | head -5
        echo ""
        echo "Hint: Use a version from the list above, or try a different channel (stable, fast, candidate)"
        echo "      You can also check https://amd64.ocp.releases.ci.openshift.org/ for CI/nightly builds"
        return 1
    fi
}
# Function to validate parameters and set defaults
validate_and_set_defaults() {
    echo "Validating parameters and setting defaults..."

    # OCP version to test
    OCP_VERSION="${OCP_VERSION:-4.19}"
    # Validate OCP version format (X.Y or X.Y.Z)
    if [[ ! "${OCP_VERSION}" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        echo "ERROR: Invalid OCP_VERSION format. Expected format: X.Y or X.Y.Z (e.g., 4.19 or 4.20.6)"
        exit 1
    fi

    # UPI installer version - always X.Y (major.minor only)
    UPI_INSTALLER_VERSION=$(echo "${OCP_VERSION}" | cut -d'.' -f1,2)

    # OCP release channel (stable, fast, candidate, eus)
    OCP_CHANNEL="${OCP_CHANNEL:-fast}"
    # Validate OCP_CHANNEL
    if [[ ! "${OCP_CHANNEL}" =~ ^(stable|fast|candidate|eus)$ ]]; then
        echo "ERROR: OCP_CHANNEL must be one of: stable, fast, candidate, eus. Got: ${OCP_CHANNEL}"
        exit 1
    fi

    # If a specific patch version (X.Y.Z) is requested, verify it exists in the channel
    if [[ "${OCP_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        if ! check_version_in_channel "${OCP_VERSION}" "${OCP_CHANNEL}"; then
            exit 1
        fi
    fi

    # AWS Region Configuration
    AWS_REGION_OVERRIDE="${AWS_REGION_OVERRIDE:-us-east-2}"

    # Azure Region Configuration
    CUSTOM_AZURE_REGION="${CUSTOM_AZURE_REGION:-eastus}"

    # OSC Version Configuration
    EXPECTED_OSC_VERSION="${EXPECTED_OSC_VERSION:-1.10.1}"

    # Kata RPM Configuration
    INSTALL_KATA_RPM="${INSTALL_KATA_RPM:-false}"
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

    # test is Pre-GA for brew builds or GA for operators/rpms already on OCP
    # this triggers the mirror redirect install, creating brew & trustee catsrc,
    TEST_RELEASE_TYPE="${TEST_RELEASE_TYPE:-Pre-GA}"
    # Validate TEST_RELEASE_TYPE
    if [[ "${TEST_RELEASE_TYPE}" != "Pre-GA" && "${TEST_RELEASE_TYPE}" != "GA" ]]; then
        echo "ERROR: TEST_RELEASE_TYPE should be 'Pre-GA' or 'GA', got: ${TEST_RELEASE_TYPE}"
        exit 1
    fi

    # Prow Run Type depends on TEST_RELEASE_TYPE
    if [[ "${TEST_RELEASE_TYPE}" == "Pre-GA" ]]; then
        PROW_RUN_TYPE="candidate"
    else
        PROW_RUN_TYPE="release"
        CATALOG_SOURCE_NAME="redhat-operators"
        INSTALL_KATA_RPM="false"
    fi

    # After the tests finish, wait before killing the cluster
    SLEEP_DURATION="${SLEEP_DURATION:-0h}"
    # Validate SLEEP_DURATION format (0-12 followed by 'h')
    if ! [[ "${SLEEP_DURATION}" =~ ^(1[0-2]|[0-9])h$ ]]; then
        echo "ERROR: SLEEP_DURATION must be a number between 0-12 followed by 'h' (e.g., 2h, 8h), got: ${SLEEP_DURATION}"
        exit 1
    fi

    # Allow override of test scenarios
    TEST_SCENARIOS="${TEST_SCENARIOS:-sig-kata.*Kata Author}"

    # Let the tests run for this many minutes before killing the cluster and interupting the test
    TEST_TIMEOUT="${TEST_TIMEOUT:-90}"
    # Validate TEST_TIMEOUT is numeric
    if ! [[ "${TEST_TIMEOUT}" =~ ^[0-9]+$ ]]; then
        echo "ERROR: TEST_TIMEOUT should be numeric, got: ${TEST_TIMEOUT}"
        exit 1
    fi

    # Must-gather Configuration
    ENABLE_MUST_GATHER="${ENABLE_MUST_GATHER:-true}"
    # Validate ENABLE_MUST_GATHER
    if [[ "${ENABLE_MUST_GATHER}" != "true" && "${ENABLE_MUST_GATHER}" != "false" ]]; then
        echo "ERROR: ENABLE_MUST_GATHER should be 'true' or 'false', got: ${ENABLE_MUST_GATHER}"
        exit 1
    fi

    # Must-gather image to use for collecting debug information
    MUST_GATHER_IMAGE="${MUST_GATHER_IMAGE:-registry.redhat.io/openshift-sandboxed-containers/osc-must-gather-rhel9:latest}"

    # Only collect must-gather on test failure
    MUST_GATHER_ON_FAILURE_ONLY="${MUST_GATHER_ON_FAILURE_ONLY:-true}"
    # Validate MUST_GATHER_ON_FAILURE_ONLY
    if [[ "${MUST_GATHER_ON_FAILURE_ONLY}" != "true" && "${MUST_GATHER_ON_FAILURE_ONLY}" != "false" ]]; then
        echo "ERROR: MUST_GATHER_ON_FAILURE_ONLY should be 'true' or 'false', got: ${MUST_GATHER_ON_FAILURE_ONLY}"
        exit 1
    fi

    # Trustee URL Configuration (defaults to empty string)
    TRUSTEE_URL="${TRUSTEE_URL:-""}"

    # Init Data Configuration (defaults to empty string)
    INITDATA="${INITDATA:-""}"

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

      # Extract expected OSC version from catalog tag if it matches X.Y.Z-[0-9]+ format
      extracted_version=$(get_expected_version "${OSC_CATALOG_TAG}")
      if [[ -n "${extracted_version}" ]]; then
          EXPECTED_OSC_VERSION="${extracted_version}"
          echo "Extracted EXPECTED_OSC_VERSION from OSC_CATALOG_TAG: ${EXPECTED_OSC_VERSION}"
      fi

      CATALOG_SOURCE_IMAGE="${CATALOG_SOURCE_IMAGE:-quay.io/redhat-user-workloads/ose-osc-tenant/osc-test-fbc:${OSC_CATALOG_TAG}}"
      CATALOG_SOURCE_NAME="${CATALOG_SOURCE_NAME:-brew-catalog}"
    else # GA
      CATALOG_SOURCE_NAME="redhat-operators"
      CATALOG_SOURCE_IMAGE=""
    fi
}

# Function to show usage
show_usage() {
    echo "Usage: $0 <command>"
    echo ""
    echo "Commands:"
    echo "  create            Create prowjob configuration files"
    echo "  run               Run prowjobs from YAML configuration"
	echo "  update_templates  Regenerate the ci-operator/config/openshift/sandboxed-containers-operator templates using default values (unless overridden)"
    echo ""
    echo "Examples:"
    echo "  $0 create"
    echo "  $0 run /path/to/job_yaml.yaml"
    echo "  $0 run /path/to/job_yaml.yaml azure-ipi-kata"
    echo ""
    echo "Environment variables for 'create' command:"
    echo "  ARO_CLUSTER_VERSION            - ARO cluster version (default: ${ARO_CLUSTER_VERSION})"
    echo "  OCP_VERSION                    - OpenShift version (default: 4.19)"
    echo "  OCP_CHANNEL                    - Release channel: stable, fast, candidate, eus (default: fast)"
    echo "  TEST_RELEASE_TYPE              - Test release type: Pre-GA or GA (default: Pre-GA)"
    echo "  EXPECTED_OSC_VERSION           - Expected OSC version (default: 1.10.1)"
    echo "  INSTALL_KATA_RPM               - Install Kata RPM: true or false (default: true)"
    echo "  KATA_RPM_VERSION               - Kata RPM version (default: 3.17.0-3.rhaos4.19.el9)"
    echo "  SLEEP_DURATION                 - Sleep duration after tests (default: 0h)"
    echo "  TEST_SCENARIOS                 - Test scenarios filter (default: sig-kata.*Kata Author)"
    echo "  TEST_TIMEOUT                   - Test timeout in minutes (default: 90)"
    echo "  ENABLE_MUST_GATHER             - Enable must-gather: true or false (default: true)"
    echo "  MUST_GATHER_IMAGE              - Must-gather image (default: registry.redhat.io/openshift-sandboxed-containers/osc-must-gather-rhel9:latest)"
    echo "  MUST_GATHER_ON_FAILURE_ONLY    - Must-gather on failure only: true or false (default: true)"
    echo "  AWS_REGION_OVERRIDE            - AWS region (default: us-east-2)"
    echo "  CUSTOM_AZURE_REGION            - Azure region (default: eastus)"
    echo "  OSC_CATALOG_TAG                - OSC catalog tag (auto-detected if not provided)"
    echo "  TRUSTEE_URL                    - Trustee URL (default: empty)"
    echo "  INITDATA                       - Initdata from Trustee(default: empty) The gzipped and base64 encoded initdata.toml file from Trustee"
}

# Main function
main() {
    # Parse command line arguments
    if [[ $# -eq 0 ]]; then
        echo "ERROR: No command specified"
        echo ""
        show_usage
        exit 1
    fi

    COMMAND="$1"
    shift

    # Validate command and dispatch
    case "${COMMAND}" in
        create)
            command_create
            ;;
        run)
            command_run "$@"
            ;;
		update_templates)
			command_update_templates
			;;
        *)
            echo "ERROR: Unknown command '${COMMAND}'"
            echo ""
            show_usage
            exit 1
            ;;
    esac
}

# Generate one variant of our workflow
generate_workflow() {
  local platform=$1       # e.g. azure or aws
  local profile=$2        # e.g. azure-qe or aws-sandboxed-containers-operator
  local workflow=$3       # e.g. sandboxed-containers-operator-e2e-azure
  local workload=$4       # e.g. kata, peerpods, coco
  local cron="0 0 31 2 1"

  echo "- as: ${platform}-ipi-${workload}"
  echo "  cron: ${cron}"
  echo "  steps:"
  echo "    cluster_profile: ${profile}"
  echo "    env:"

  # Collect environment variables into a temporary array
  local env_vars=()
  local kata_rpm_version
  kata_rpm_version="${KATA_RPM_VERSION:-}"

  # Platform-specific
  if [[ $platform == "azure" ]]; then
    env_vars+=("BASE_DOMAIN: qe.azure.devcluster.openshift.com")
    env_vars+=("CUSTOM_AZURE_REGION: ${CUSTOM_AZURE_REGION}")
  elif [[ $platform == "aro" ]]; then
    env_vars+=("ARO_CLUSTER_VERSION: \"${ARO_CLUSTER_VERSION}\"")
    env_vars+=("LOCATION: ${CUSTOM_AZURE_REGION}")
    env_vars+=("HYPERSHIFT_AZURE_LOCATION: ${CUSTOM_AZURE_REGION}")
    kata_rpm_version="${kata_rpm_version//$OCP_VERSION/$ARO_CLUSTER_VERSION}"
  elif [[ $platform == "aws" ]]; then
    env_vars+=("AWS_REGION_OVERRIDE: ${AWS_REGION_OVERRIDE}")
  fi

  # Common
  env_vars+=(
    "CATALOG_SOURCE_IMAGE: ${CATALOG_SOURCE_IMAGE:-\"\"}"
    "CATALOG_SOURCE_NAME: ${CATALOG_SOURCE_NAME}"
    "ENABLE_MUST_GATHER: \"${ENABLE_MUST_GATHER}\""
    "EXPECTED_OPERATOR_VERSION: ${EXPECTED_OSC_VERSION}"
    "INITDATA: ${INITDATA:-\"\"}"
    "INSTALL_KATA_RPM: \"${INSTALL_KATA_RPM}\""
    "KATA_RPM_VERSION: ${kata_rpm_version:-\"\"}"
    "MUST_GATHER_IMAGE: ${MUST_GATHER_IMAGE}"
    "MUST_GATHER_ON_FAILURE_ONLY: \"${MUST_GATHER_ON_FAILURE_ONLY}\""
    "SLEEP_DURATION: ${SLEEP_DURATION}"
    "TEST_FILTERS: ~DisconnectedOnly&;~Disruptive&"
    "TEST_RELEASE_TYPE: ${TEST_RELEASE_TYPE}"
    "TEST_SCENARIOS: ${TEST_SCENARIOS}"
    "TEST_TIMEOUT: \"${TEST_TIMEOUT}\""
    "TRUSTEE_URL: ${TRUSTEE_URL:-\"\"}"
  )

  # Workload-specific
  case $workload in
    kata)
      # nothing extra for kata beyond defaults
      ;;
    peerpods|coco)
      env_vars+=("ENABLEPEERPODS: \"true\"")
      env_vars+=("RUNTIMECLASS: kata-remote")
      env_vars+=("WORKLOAD_TO_TEST: ${workload/peerpods/peer-pods}")
      ;;
  esac

  # Sort and print alphabetically
  printf '%s\n' "${env_vars[@]}" | sort | sed 's/^/      /'

  echo "    workflow: ${workflow}"
  echo "  timeout: 24h0m0s"
}

# Function to create prowjob configuration
command_create() {
    echo "=========================================="
    echo "Sandboxed Containers Operator - Prowjob Configuration Generator"

    # Call the validation function
    validate_and_set_defaults

    # Generate output file path
    OCP_PROWJOB_VERSION=$(echo "${OCP_VERSION}" | tr -d '.' )
    OUTPUT_FILE="openshift-sandboxed-containers-operator-devel__downstream-${PROW_RUN_TYPE}${OCP_PROWJOB_VERSION}.yaml"
    echo "Creating prowjob configuration..."

    # Backup existing file if it exists
    if [[ -f "${OUTPUT_FILE}" ]]; then
        echo "Backing up existing file: ${OUTPUT_FILE}.backup"
        cp "${OUTPUT_FILE}" "${OUTPUT_FILE}.backup"
    fi

    # Create the prowjob configuration file

    cat > "${OUTPUT_FILE}" <<EOF
base_images:
  tests-private:
    name: tests-private
    namespace: ci
    tag: "4.21"
  upi-installer:
    name: "${UPI_INSTALLER_VERSION}"
    namespace: ocp
    tag: upi-installer
releases:
  latest:
    release:
      architecture: amd64
      channel: ${OCP_CHANNEL}
      version: "${OCP_VERSION}"
resources:
  '*':
    requests:
      cpu: 100m
      memory: 200Mi
tests:
EOF
generate_workflow azure azure-qe sandboxed-containers-operator-e2e-azure kata >> "${OUTPUT_FILE}"
generate_workflow azure azure-qe sandboxed-containers-operator-e2e-azure peerpods >> "${OUTPUT_FILE}"
generate_workflow azure azure-qe sandboxed-containers-operator-e2e-azure coco >> "${OUTPUT_FILE}"
generate_workflow aro azure-qe sandboxed-containers-operator-e2e-aro peerpods >> "${OUTPUT_FILE}"
generate_workflow aro azure-qe sandboxed-containers-operator-e2e-aro coco >> "${OUTPUT_FILE}"
generate_workflow aws aws-sandboxed-containers-operator sandboxed-containers-operator-e2e-aws peerpods >> "${OUTPUT_FILE}"
generate_workflow aws aws-sandboxed-containers-operator sandboxed-containers-operator-e2e-aws coco >> "${OUTPUT_FILE}"
	cat >> "${OUTPUT_FILE}" <<EOF
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
        echo "Validating YAML: yq eval '.' ${OUTPUT_FILE}"
        if yq eval '.' "${OUTPUT_FILE}" ; then
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
    echo "  • OCP Channel: ${OCP_CHANNEL}"
    echo "  • UPI Installer Version: ${UPI_INSTALLER_VERSION}"
    echo "  • ARO Version: ${ARO_CLUSTER_VERSION}"
    echo "  • Prow Run Type: ${PROW_RUN_TYPE}"
    echo "  • Test Release Type: ${TEST_RELEASE_TYPE}"
    echo "  • Expected OSC Version: ${EXPECTED_OSC_VERSION}"
    echo "  • Expected Trustee Version: ${EXPECTED_TRUSTEE_VERSION:-N/A}"
    echo "  • AWS Region: ${AWS_REGION_OVERRIDE}"
    echo "  • Azure Region: ${CUSTOM_AZURE_REGION}"
    echo "  • Kata RPM: ${INSTALL_KATA_RPM} (${KATA_RPM_VERSION})"
    echo "  • Sleep Duration: ${SLEEP_DURATION}"
    echo "  • Test Timeout: ${TEST_TIMEOUT}"

    if [[ "${TEST_RELEASE_TYPE}" == "Pre-GA" ]]; then
        echo "  • Catalog Source: ${CATALOG_SOURCE_NAME} (${CATALOG_SOURCE_IMAGE})"
    else
        echo "  • Catalog Source: ${CATALOG_SOURCE_NAME}"
    fi

    echo "=========================================="
    echo "Generated file: ${OUTPUT_FILE}"
    echo "File size: ${file_size} bytes"
    echo "=========================================="
    echo "Next steps you have two options:"
    echo ""
    echo "Option A - Run jobs immediately:"
    echo "1. Set your Prow API token:"
    echo "   export PROW_API_TOKEN=your_token_here"
    echo ""
    echo "2. Run all jobs from the generated file:"
    echo "   ./sandboxed-containers-operator-create-prowjob-commands.sh run ${OUTPUT_FILE}"
    echo ""
    echo "3. Or run specific jobs:"
    echo "   ./sandboxed-containers-operator-create-prowjob-commands.sh run ${OUTPUT_FILE} azure-ipi-kata"
    echo ""
    echo "Option B - Submit configuration to CI:"
    echo "1. Review the created configuration file:"
    echo "   cat ${OUTPUT_FILE}"
    echo ""
    echo "2. Move it to the appropriate directory:"
    echo "mv ${OUTPUT_FILE} ci-operator/config/openshift/sandboxed-containers-operator/"
    echo ""
    echo "3. Add to git:"
    echo "git add ci-operator/config/openshift/sandboxed-containers-operator/${OUTPUT_FILE}"
    echo ""
    echo "4. Generate and update CI configuration before creating PR:"
    echo "make ci-operator-config && make registry-metadata && make prow-config && make jobs && make update"
    echo ""
    echo "5. git add changes, commit and push to PR"
    echo ""
}

# Function to run prowjobs
command_run() {
    echo "=========================================="
    echo "Sandboxed Containers Operator - Run Prowjobs"
    echo ""

    # Check if job_yaml file is provided
    if [[ $# -eq 0 ]]; then
        echo "ERROR: No job YAML file specified"
        echo ""
        echo "Usage: $0 run <job_yaml_file> [job_names...]"
        echo ""
        echo "Examples:"
        echo "  $0 run /path/to/job_yaml.yaml"
        echo "  $0 run /path/to/job_yaml.yaml azure-ipi-kata"
        echo "  $0 run /path/to/job_yaml.yaml azure-ipi-kata azure-ipi-peerpods"
        echo ""
        exit 1
    fi

    JOB_YAML_FILE="$1"
    shift

    # Check if job_yaml file exists
    if [[ ! -f "${JOB_YAML_FILE}" ]]; then
        echo "ERROR: Job YAML file not found: ${JOB_YAML_FILE}"
        exit 1
    fi

    echo "Job YAML file: ${JOB_YAML_FILE}"

    # Extract metadata from job_yaml
    ORG=$(yq eval '.zz_generated_metadata.org' "${JOB_YAML_FILE}")
    REPO=$(yq eval '.zz_generated_metadata.repo' "${JOB_YAML_FILE}")
    BRANCH=$(yq eval '.zz_generated_metadata.branch' "${JOB_YAML_FILE}")
    VARIANT=$(yq eval '.zz_generated_metadata.variant' "${JOB_YAML_FILE}")

    if [[ -z "${ORG}" || -z "${REPO}" || -z "${BRANCH}" || -z "${VARIANT}" ]]; then
        echo "ERROR: Missing required metadata in job YAML file"
        echo "Required fields: org, repo, branch, variant in zz_generated_metadata section"
        exit 1
    fi

    # Generate job name prefix
    JOB_PREFIX="periodic-ci-${ORG}-${REPO}-${BRANCH}-${VARIANT}"
    echo "Job name prefix: ${JOB_PREFIX}"

    # Determine job names to run
    if [[ $# -eq 0 ]]; then
        # No specific jobs provided, extract all 'as' values from tests
        echo "No specific jobs provided, extracting all jobs from YAML..."
        mapfile -t JOB_NAMES < <(yq eval '.tests[].as' "${JOB_YAML_FILE}")
    else
        # Use provided job names
        echo "Using provided job names: $*"
        JOB_NAMES=("$@")
    fi

    if [[ ${#JOB_NAMES[@]} -eq 0 ]]; then
        echo "ERROR: No jobs found to run"
        exit 1
    fi

    echo ""
    echo "Jobs to run:"
    for job_suffix in "${JOB_NAMES[@]}"; do
        full_job_name="${JOB_PREFIX}-${job_suffix}"
        echo "  - ${full_job_name}"
    done

    echo ""
    echo "Preparing job execution..."

    # Check for PROW_API_TOKEN
    if [[ -z "${PROW_API_TOKEN:-}" ]]; then
        echo "ERROR: PROW_API_TOKEN environment variable is not set"
        echo "Please set your Prow API token:"
        echo "  export PROW_API_TOKEN=your_token_here"
        exit 1
    fi
    echo "✓ PROW_API_TOKEN is set"

    # Convert job YAML to JSON
    echo "Converting job YAML to JSON..."
    if ! yq -o=json "${JOB_YAML_FILE}" | jq -Rs . > config.json; then
        echo "ERROR: Failed to convert YAML to JSON"
        exit 1
    fi
    echo "✓ Job configuration converted to JSON"

    # Trigger jobs
    echo ""
    echo "Triggering jobs..."

    for job_suffix in "${JOB_NAMES[@]}"; do
        full_job_name="${JOB_PREFIX}-${job_suffix}"
        echo ""
        echo "Triggering job: ${full_job_name}"

        # Create payload
        UNRESOLVED_SPEC=$(cat config.json)
        payload=$(jq -n --arg job "${full_job_name}" \
           --argjson config "${UNRESOLVED_SPEC}" \
           '{
               "job_name": $job,
               "job_execution_type": "1",
               "pod_spec_options": {
                  "envs": {
                     "UNRESOLVED_CONFIG": $config
                   },
                }
            }')

        # Make API call
        echo "Making API call to trigger job..."
        if curl -s -X POST -H "Authorization: Bearer ${PROW_API_TOKEN}" \
            -H "Content-Type: application/json" -d "${payload}" \
            "${GANGWAY_API_ENDPOINT}" > "output_${job_suffix}.json"; then

            # Extract job ID
            job_id=$(jq -r '.id' "output_${job_suffix}.json")
            if [[ "${job_id}" != "null" && -n "${job_id}" ]]; then
                echo "✓ Job triggered successfully!"
                echo "  Job ID: ${job_id}"
                echo "  Output saved to: output_${job_suffix}.json"

                # Get job status
                echo "Fetching job status..."
                curl -s -X GET -H "Authorization: Bearer ${PROW_API_TOKEN}" \
                    "${GANGWAY_API_ENDPOINT}/${job_id}" > "status_${job_suffix}.json"
                echo "  Status saved to: status_${job_suffix}.json"
            else
                echo "✗ Failed to get job ID from response"
                echo "Response content:"
                cat "output_${job_suffix}.json"
            fi
        else
            echo "✗ Failed to trigger job"
            echo "Check output_${job_suffix}.json for details"
        fi
    done

    echo ""
    echo "Job triggering completed!"
    echo "Check the output_*.json and status_*.json files for details"
}

command_update_templates() {
	local target_dir
	local files
	target_dir="$(realpath "$(dirname "${BASH_SOURCE[0]}")")/../../../config/openshift/sandboxed-containers-operator"
	files="$(ls openshift-sandboxed-containers-operator-devel__downstream-{candidate,release}*.yaml 2>/dev/null)" ||:
	if [ -n "$files" ]; then
		echo "There are previously generated workflows, do you want to delete them? ${PWD}"
		rm -i $files
	fi
	KATA_RPM_VERSION=3.21.0-3.rhaos4.19.el9 TEST_RELEASE_TYPE=Pre-GA "$(dirname "${BASH_SOURCE[0]}")"/sandboxed-containers-operator-create-prowjob-commands.sh create
	INSTALL_KATA_RPM=false TEST_RELEASE_TYPE=GA "$(dirname "${BASH_SOURCE[0]}")"/sandboxed-containers-operator-create-prowjob-commands.sh create
	mv openshift-sandboxed-containers-operator-devel__downstream-candidate*.yaml "${target_dir}/openshift-sandboxed-containers-operator-devel__downstream-candidate.yaml"
	mv openshift-sandboxed-containers-operator-devel__downstream-release*.yaml "${target_dir}/openshift-sandboxed-containers-operator-devel__downstream-release.yaml"
	echo
	echo "Review the changes by 'git diff', then run 'make ci-operator-config && make jobs'"
}

# Call main function with all command line arguments
main "$@"
