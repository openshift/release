#!/bin/bash
set -euo pipefail

source "${SHARED_DIR}/telco-kpis-common-functions.sh"

# Check MULTISTAGE skip override (exits if "true", clears JSON skip if "false")
skip_via_gangway_overrides

export_env_vars_from_json 'push_to_data_lake' "${REPORTING_SETTINGS:-}" "${REPORTING_SETTINGS_DEFAULTS:-}"
export_env_vars_from_json 'splunk' "${REPORTING_SETTINGS:-}" "${REPORTING_SETTINGS_DEFAULTS:-}"
export_env_vars_from_json 'sumologic' "${REPORTING_SETTINGS:-}" "${REPORTING_SETTINGS_DEFAULTS:-}"
apply_gangway_overrides

# Helper function to quote YAML strings safely
_yaml_quote() { local v="${1//\\/\\\\}"; v="${v//\"/\\\"}"; printf '%s' "$v"; }

main() {
    # Install unified exit handler (handles CONTINUE_ON_FAIL, DEBUG_ON_FAIL, and cleanup)
    setup_telco_kpis_exit_handler

    [[ $- == *x* ]] && _was_tracing=true || _was_tracing=false

    # Build test names parameter from REPORTING_SETTINGS (exported as TEST_NAMES)
    TEST_NAMES_PARAM="${TEST_NAMES:-all}"

    echo "=========================================="
    echo "Push to Data Lake - Configuration"
    echo "=========================================="
    echo "Test Names:      ${TEST_NAMES_PARAM}"
    echo "Destination:     ${DATA_LAKE_DESTINATION}"
    echo "Formal Test:     ${FORMAL_TEST}"
    echo "========================================"

    # Validate required parameters
    if [[ -z "${HUB_CLUSTER}" ]]; then
        echo "ERROR: HUB_CLUSTER environment variable is required"
        return 1
    fi

    if [[ -z "${SPOKE_CLUSTER}" ]]; then
        echo "ERROR: SPOKE_CLUSTER environment variable is required"
        return 1
    fi

    setup_ansible_inventory "${SPOKE_CLUSTER}" "${HUB_CLUSTER}"

    cd /eco-ci-cd

    DEBUG_FLAG=""
    if [ "${DEBUG}" = "true" ]; then
        DEBUG_FLAG="-vvv"
    fi

    # Write sensitive credentials to a temporary extra-vars file so they
    # never appear in command-line expansions or xtrace output.
    SENSITIVE_VARS_FILE=$(mktemp /tmp/sensitive-vars-XXXXXX.yml)
    echo "---" > "${SENSITIVE_VARS_FILE}"

    # Register cleanup handler for sensitive credentials
    _cleanup_sensitive_vars() {
        if [[ -f "${SENSITIVE_VARS_FILE}" ]]; then
            rm -f "${SENSITIVE_VARS_FILE}"
        fi
    }
    add_cleanup_handler _cleanup_sensitive_vars

    # Register artifact gathering handler (always runs, even on playbook failure)
    _gather_artifacts() {
        echo "Collecting artifacts..."
        mkdir -p "${ARTIFACT_DIR}"

        # Playbook writes spoke-specific filename, copy to generic name for downstream consumers
        local spoke_result_file="${ARTIFACT_DIR:-/artifacts}/push-to-data-lake-result-for-${SPOKE_CLUSTER}.json"
        if [ -f "${spoke_result_file}" ]; then
            # Copy to ARTIFACT_DIR as generic name (Prow collects this)
            cp "${spoke_result_file}" "${ARTIFACT_DIR}/push-to-data-lake-result.json" || true

            # Copy to SHARED_DIR as generic name (for downstream steps)
            cp "${spoke_result_file}" "${SHARED_DIR}/push-to-data-lake-result.json" || true

            echo "✓ Artifacts collected to ${ARTIFACT_DIR}/ and ${SHARED_DIR}/"
        else
            echo "WARNING: Result JSON not found at ${spoke_result_file}"
        fi
    }
    add_cleanup_handler _gather_artifacts

    # Add Splunk credentials if destination is splunk
    if [ "${DATA_LAKE_DESTINATION}" = "splunk" ]; then
        if [ -f /var/splunk/splunk_hec_token ]; then
            set +x
            {
                # Splunk-specific variables (for backwards compatibility)
                echo "splunk_hec_url: \"$(_yaml_quote "${SPLUNK_HEC_URL:-}")\""
                echo "splunk_hec_token: \"$(_yaml_quote "$(cat /var/splunk/splunk_hec_token)")\""
                # Generic variables (for playbook)
                echo "data_lake_url: \"$(_yaml_quote "${SPLUNK_HEC_URL:-}")\""
                echo "data_lake_token: \"$(_yaml_quote "$(cat /var/splunk/splunk_hec_token)")\""
            } >> "${SENSITIVE_VARS_FILE}"
            $_was_tracing && set -x
        else
            echo "ERROR: Splunk HEC token not found at /var/splunk/splunk_hec_token"
            return 1
        fi
    fi

    # Add SumoLogic credentials if destination is sumologic
    if [ "${DATA_LAKE_DESTINATION}" = "sumologic" ]; then
        if [ -f /var/sumologic/sumologic_hec_token ]; then
            set +x
            {
                # SumoLogic-specific variables (for backwards compatibility)
                echo "sumologic_hec_url: \"$(_yaml_quote "${SUMOLOGIC_HEC_URL:-}")\""
                echo "sumologic_hec_token: \"$(_yaml_quote "$(cat /var/sumologic/sumologic_hec_token)")\""
                # Generic variables (for playbook)
                echo "data_lake_url: \"$(_yaml_quote "${SUMOLOGIC_HEC_URL:-}")\""
                echo "data_lake_token: \"$(_yaml_quote "$(cat /var/sumologic/sumologic_hec_token)")\""
            } >> "${SENSITIVE_VARS_FILE}"
            $_was_tracing && set -x
        else
            echo "WARNING: SumoLogic HEC token not found at /var/sumologic/"
            echo "WARNING: SumoLogic push will fail (expected - stub implementation)"
        fi
    fi

    echo "=========================================="
    echo "Executing push-to-data-lake playbook..."
    echo "=========================================="

    # Run playbook - if it fails, cleanup and artifact handlers still run
    ansible-playbook ${DEBUG_FLAG} \
        ./playbooks/telco-kpis/push-to-data-lake.yml \
        -i ./inventories/ocp-deployment/build-inventory.py \
        -e "hub_cluster=${HUB_CLUSTER}" \
        -e "spoke_cluster=${SPOKE_CLUSTER}" \
        -e "test_names=${TEST_NAMES_PARAM}" \
        -e "data_lake_destination=${DATA_LAKE_DESTINATION}" \
        -e "formal_test=${FORMAL_TEST}" \
        -e "ci_type=prow" \
        -e "ci_job_name=${JOB_NAME:-unknown}" \
        -e "ci_build_number=${BUILD_ID:-unknown}" \
        -e "@${SENSITIVE_VARS_FILE}"

    # Gather artifacts now so result checking can access them
    # (Also registered as EXIT cleanup handler in case playbook fails before this point)
    _gather_artifacts

    echo "=========================================="
    echo "Checking push results..."
    echo "=========================================="

    # Parse and check results (artifacts already collected by cleanup handler)
    # Note: Search URL and error details are in the JSON artifact, not logged to avoid
    # exposing internal hostnames or sensitive payload data
    RESULT_JSON="${ARTIFACT_DIR}/push-to-data-lake-result.json"
    if [ ! -f "${RESULT_JSON}" ]; then
        echo "ERROR: Push result artifact not found; push status is unknown"
        [[ "${DATA_LAKE_DESTINATION}" == "splunk" ]] && return 1
    else
        SUCCESS=$(python3 -c 'import json,sys; print(str(json.load(open(sys.argv[1])).get("success")).lower())' "${RESULT_JSON}")

        if [[ "${SUCCESS}" == "true" ]]; then
            echo "✓ Push to ${DATA_LAKE_DESTINATION} completed successfully"
            echo "  (Search URL available in push-to-data-lake-result.json artifact)"
        else
            echo "WARNING: Push to ${DATA_LAKE_DESTINATION} was not successful"
            echo "  (Error details available in push-to-data-lake-result.json artifact)"

            # Only fail for Splunk, SumoLogic failure is expected (stub)
            if [[ "${DATA_LAKE_DESTINATION}" == "splunk" ]]; then
                return 1
            fi
        fi
    fi

    echo "=========================================="
    echo "Push to Data Lake - Complete"
    echo "=========================================="
}

main "$@"
