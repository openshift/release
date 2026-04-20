#!/bin/bash

# Non-fatal execution — upload failures must not fail the CI job
set -o nounset
set -o pipefail
set +o errexit

echo "=========================================="
echo "ReportPortal Upload Step"
echo "=========================================="

if [[ "${DISABLE_REPORTPORTAL:-false}" == "true" ]]; then
    echo "ReportPortal upload disabled via DISABLE_REPORTPORTAL=true, skipping"
    exit 0
fi

# ============================================================================
# Determine Dynamic Launch Name and Run/Release Type
# ============================================================================
# These functions set global variables instead of echoing, to avoid subshell
# issues with exported variables like RUN_TYPE.

# Global variables set by these functions
DYNAMIC_LAUNCH_NAME=""
RUN_TYPE=""
RELEASE_TYPE=""

get_chart_version() {
    # Returns chart version from env var or version_info.json
    local chart_version="${HELM_CHART_VERSION:-}"
    if [[ -z "$chart_version" ]] && [[ -f "${SHARED_DIR}/version_info.json" ]]; then
        chart_version=$(jq -r '.helm_chart_version // empty' "${SHARED_DIR}/version_info.json" 2>/dev/null || true)
    fi
    echo "$chart_version"
}

determine_run_type() {
    # Sets RUN_TYPE based on Prow environment variables
    if [[ "${JOB_TYPE:-}" == "periodic" ]]; then
        RUN_TYPE="nightly"
    elif [[ -n "${PULL_NUMBER:-}" ]]; then
        RUN_TYPE="pr"
    elif [[ "${JOB_TYPE:-}" == "postsubmit" ]]; then
        RUN_TYPE="postsubmit"
    else
        RUN_TYPE="adhoc"
    fi
    export RUN_TYPE
}

determine_release_type() {
    # Sets RELEASE_TYPE based on CHART_REF_RESOLVED, USE_HELM_DEVEL, or version string
    # CHART_REF_RESOLVED and USE_HELM_DEVEL are exported by the e2e step
    
    # Check authoritative flags from e2e step first
    if [[ "${USE_HELM_DEVEL:-false}" == "true" ]]; then
        # Using --devel flag means we're testing an RC
        RELEASE_TYPE="rc"
    elif [[ "${CHART_REF_RESOLVED:-}" == "main" ]]; then
        # Explicitly testing main branch
        RELEASE_TYPE="main"
    elif [[ -n "${CHART_REF_RESOLVED:-}" ]] && [[ "${CHART_REF_RESOLVED}" == *"-rc"* ]]; then
        # Resolved ref contains RC indicator
        RELEASE_TYPE="rc"
    else
        # Fall back to inferring from chart version
        local chart_version
        chart_version=$(get_chart_version)
        if [[ "$chart_version" == *"-rc"* ]]; then
            RELEASE_TYPE="rc"
        elif [[ -n "$chart_version" ]] && [[ "$chart_version" != "unknown" ]]; then
            RELEASE_TYPE="release"
        else
            RELEASE_TYPE="main"
        fi
    fi
    export RELEASE_TYPE
}

build_launch_name() {
    # Sets DYNAMIC_LAUNCH_NAME based on RUN_TYPE and chart version
    # Must be called after determine_run_type()
    local base="${LAUNCH_NAME:-insights-onprem-e2e}"
    local chart_version
    chart_version=$(get_chart_version)

    case "$RUN_TYPE" in
        nightly)
            if [[ -n "$chart_version" ]]; then
                DYNAMIC_LAUNCH_NAME="${base}-nightly-${chart_version}"
            else
                DYNAMIC_LAUNCH_NAME="${base}-nightly"
            fi
            ;;
        pr)
            DYNAMIC_LAUNCH_NAME="${base}-pr-${PULL_NUMBER}"
            ;;
        postsubmit)
            if [[ -n "$chart_version" ]]; then
                DYNAMIC_LAUNCH_NAME="${base}-postsubmit-${chart_version}"
            else
                DYNAMIC_LAUNCH_NAME="${base}-postsubmit"
            fi
            ;;
        *)
            if [[ -n "$chart_version" ]]; then
                DYNAMIC_LAUNCH_NAME="${base}-adhoc-${chart_version}"
            else
                DYNAMIC_LAUNCH_NAME="${base}-adhoc"
            fi
            ;;
    esac
    export DYNAMIC_LAUNCH_NAME
}

# ============================================================================
# Validate Prerequisites
# ============================================================================

validate_prerequisites() {
    echo "Validating prerequisites..."

    local errors=0

    # JUnit files are passed via SHARED_DIR (not ARTIFACT_DIR which is step-specific)
    if ! ls "${SHARED_DIR}"/junit_*.xml &>/dev/null; then
        echo "ERROR: No junit_*.xml files found in ${SHARED_DIR}"
        echo "  Tests may not have run or artifact collection failed"
        errors=$((errors + 1))
    else
        echo "Found JUnit files:"
        ls "${SHARED_DIR}"/junit_*.xml | sed 's/^/  - /'
    fi

    if [[ ! -f "/datarouter/secrets/username" ]] || [[ ! -f "/datarouter/secrets/password" ]]; then
        echo "ERROR: DataRouter credentials not found at /datarouter/secrets/"
        errors=$((errors + 1))
    else
        echo "DataRouter credentials mounted"
    fi

    if ! command -v droute &>/dev/null; then
        echo "ERROR: droute CLI not found in PATH"
        errors=$((errors + 1))
    else
        echo "droute CLI available: $(droute version 2>/dev/null || echo 'version unknown')"
    fi

    if [[ $errors -gt 0 ]]; then
        echo "Prerequisites validation failed with ${errors} error(s), skipping upload (non-fatal)"
        exit 0
    fi

    echo "All prerequisites validated"
}

# ============================================================================
# Extract Version and Component Information (Dynamic)
# ============================================================================

extract_version_info() {
    echo ""
    echo "Extracting version information..."

    # version_info.json is passed via SHARED_DIR from the e2e step
    if [[ ! -f "${SHARED_DIR}/version_info.json" ]]; then
        echo "version_info.json not found in SHARED_DIR, skipping metadata extraction"
        echo '[]' > "${ARTIFACT_DIR}/version_attributes.json"
        return 0
    fi

    # Dynamically extract all top-level scalar fields (excludes 'components' object)
    local top_level_attributes
    top_level_attributes=$(jq -r '
        to_entries
        | map(select(.key != "components"))
        | map({
            key: .key,
            value: (
                if .value | type == "string" then .value
                elif .value | type == "number" then .value | tostring
                else .value | tostring
                end
            )
          })
    ' "${SHARED_DIR}/version_info.json")

    # Flatten components.NAME.tag into NAME_version attributes
    local component_attributes
    component_attributes=$(jq -r '
        .components // {}
        | to_entries
        | map({
            key: (.key | gsub("-"; "_") + "_version"),
            value: (.value.tag // "unknown")
          })
    ' "${SHARED_DIR}/version_info.json")

    # Merge both sets
    jq -s '.[0] + .[1]' \
        <(echo "$top_level_attributes") \
        <(echo "$component_attributes") \
        > "${ARTIFACT_DIR}/version_attributes.json"

    local attr_count
    attr_count=$(jq 'length' "${ARTIFACT_DIR}/version_attributes.json")
    echo "Extracted ${attr_count} attributes from version_info.json"
}

# ============================================================================
# Extract Cluster Information
# ============================================================================

extract_cluster_info() {
    echo ""
    echo "Extracting cluster information..."

    if [[ -f "${SHARED_DIR}/cluster-name" ]]; then
        export CLUSTER_NAME
        CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster-name")
    else
        export CLUSTER_NAME="openshift-ci"
    fi

    if command -v oc &>/dev/null && oc whoami --show-server &>/dev/null 2>&1; then
        local api_server
        api_server=$(oc whoami --show-server)
        export CLUSTER_DOMAIN
        CLUSTER_DOMAIN=$(echo "$api_server" | sed -E 's|https?://api\.([^:]+)(:[0-9]+)?|\1|')
    else
        export CLUSTER_DOMAIN="qe.openshift.ci"
    fi

    echo "Cluster: ${CLUSTER_NAME} / ${CLUSTER_DOMAIN}"
}

# ============================================================================
# Construct Prow Job URL
# ============================================================================

construct_prow_job_url() {
    local job_base_url="https://prow.ci.openshift.org/view/gs/test-platform-results"

    if [[ -n "${PULL_NUMBER:-}" ]]; then
        export PROW_JOB_URL="${job_base_url}/pr-logs/pull/${REPO_OWNER}_${REPO_NAME}/${PULL_NUMBER}/${JOB_NAME}/${BUILD_ID}"
    else
        export PROW_JOB_URL="${job_base_url}/logs/${JOB_NAME}/${BUILD_ID}"
    fi

    echo "Prow job URL: ${PROW_JOB_URL}"
}

# ============================================================================
# Generate DataRouter Metadata
# ============================================================================

generate_datarouter_metadata() {
    echo ""
    echo "Generating DataRouter metadata..."

    local metadata_file="${ARTIFACT_DIR}/datarouter_metadata.json"

    # Determine run type, release type, and launch name (sets global variables)
    determine_run_type
    determine_release_type
    build_launch_name

    echo "Dynamic launch name: ${DYNAMIC_LAUNCH_NAME}"
    echo "Run type: ${RUN_TYPE}"
    echo "Release type: ${RELEASE_TYPE}"

    # Extract chart version for attribute
    local chart_version
    chart_version=$(get_chart_version)
    [[ -z "$chart_version" ]] && chart_version="unknown"

    local ci_attributes
    ci_attributes=$(jq -n \
        --arg cluster_name "${CLUSTER_NAME:-unknown}" \
        --arg cluster_domain "${CLUSTER_DOMAIN:-unknown}" \
        --arg jenkins_build "${BUILD_ID}" \
        --arg job_name "${JOB_NAME}" \
        --arg uploadfrom "prow" \
        --arg run_type "${RUN_TYPE}" \
        --arg release_type "${RELEASE_TYPE}" \
        --arg chart_version "${chart_version}" \
        --arg job_type "${JOB_TYPE:-unknown}" \
        --arg pull_number "${PULL_NUMBER:-}" \
        '[
          {key: "cluster_name",   value: $cluster_name},
          {key: "cluster_domain", value: $cluster_domain},
          {key: "jenkins_build",  value: $jenkins_build},
          {key: "job_name",       value: $job_name},
          {key: "uploadfrom",     value: $uploadfrom},
          {key: "run_type",       value: $run_type},
          {key: "release_type",   value: $release_type},
          {key: "chart_version",  value: $chart_version},
          {key: "job_type",       value: $job_type}
        ] + (if $pull_number != "" then [{key: "pull_number", value: $pull_number}] else [] end)')

    local version_attributes='[]'
    if [[ -f "${ARTIFACT_DIR}/version_attributes.json" ]]; then
        version_attributes=$(cat "${ARTIFACT_DIR}/version_attributes.json")
    fi

    local all_attributes
    all_attributes=$(jq -s '.[0] + .[1]' \
        <(echo "$ci_attributes") \
        <(echo "$version_attributes"))

    jq -n \
        --arg hostname "${REPORTPORTAL_HOSTNAME}" \
        --arg project "${REPORTPORTAL_PROJECT}" \
        --arg launch_name "${DYNAMIC_LAUNCH_NAME}" \
        --arg description "[View CI job](${PROW_JOB_URL})" \
        --argjson attributes "$all_attributes" \
        '{
          "targets": {
            "reportportal": {
              "disabled": false,
              "config": {
                "hostname": $hostname,
                "project": $project
              },
              "processing": {
                "apply_tfa": true,
                "property_filter": [".*"],
                "launch": {
                  "name": $launch_name,
                  "description": $description,
                  "attributes": $attributes
                }
              }
            }
          }
        }' > "$metadata_file"

    local attr_count
    attr_count=$(echo "$all_attributes" | jq 'length')
    echo "Metadata generated with ${attr_count} attributes: ${metadata_file}"
}

# ============================================================================
# Upload to DataRouter
# ============================================================================

upload_to_datarouter() {
    echo ""
    echo "=========================================="
    echo "Uploading to DataRouter"
    echo "=========================================="

    # Disable tracing — credentials in scope
    [[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
    set +x

    local username password
    username=$(cat /datarouter/secrets/username)
    password=$(cat /datarouter/secrets/password)
    local datarouter_url="https://datarouter.ccitredhat.com"

    $WAS_TRACING && set -x

    echo "DataRouter URL: ${datarouter_url}"
    echo "Results: ${SHARED_DIR}/junit_*.xml"

    local max_attempts=10
    local wait_seconds=10
    local upload_succeeded=false

    for ((attempt = 1; attempt <= max_attempts; attempt++)); do
        echo "Upload attempt ${attempt}/${max_attempts}..."

        [[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
        set +x
        local output
        if output=$(droute send \
            --metadata "${ARTIFACT_DIR}/datarouter_metadata.json" \
            --url "${datarouter_url}" \
            --username "${username}" \
            --password "${password}" \
            --results "${SHARED_DIR}/junit_*.xml" \
            --verbose --wirelog 2>&1); then
            $WAS_TRACING && set -x
            echo "Upload successful"
            echo "$output"
            local request_id
            request_id=$(echo "$output" | grep "request:" | awk '{print $2}')
            if [[ -n "$request_id" ]]; then
                echo "DataRouter Request ID: ${request_id}"
                echo "$request_id" > "${ARTIFACT_DIR}/datarouter_request_id.txt"
            fi
            upload_succeeded=true
            break
        else
            $WAS_TRACING && set -x
            echo "Upload attempt ${attempt} failed:"
            echo "$output"
            if [[ $attempt -lt $max_attempts ]]; then
                echo "Waiting ${wait_seconds}s before retry..."
                sleep $wait_seconds
            fi
        fi
    done

    if [[ "$upload_succeeded" == false ]]; then
        echo ""
        echo "Upload failed after ${max_attempts} attempts (non-fatal)"
        echo "For help: #forum-dno-datarouter"
        echo "Docs: https://spaces.redhat.com/spaces/CentralCI/pages/115488042/D+O+Data+Router"
        echo "failed" > "${ARTIFACT_DIR}/reportportal_upload_status.txt"
        return 0
    fi

    echo ""
    echo "=========================================="
    echo "ReportPortal Upload Complete"
    echo "=========================================="
    echo "View results: https://${REPORTPORTAL_HOSTNAME}/ui/#${REPORTPORTAL_PROJECT}/launches/all"
    echo "success" > "${ARTIFACT_DIR}/reportportal_upload_status.txt"
}

# ============================================================================
# Main
# ============================================================================

echo "Job:      ${JOB_NAME}"
echo "Build ID: ${BUILD_ID}"
echo ""

validate_prerequisites
extract_version_info
extract_cluster_info
construct_prow_job_url
generate_datarouter_metadata
upload_to_datarouter

echo ""
echo "ReportPortal step complete"
exit 0
