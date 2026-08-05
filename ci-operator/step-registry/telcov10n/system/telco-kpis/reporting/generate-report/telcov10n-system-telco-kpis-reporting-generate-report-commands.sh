#!/bin/bash
set -euo pipefail

source "${SHARED_DIR}/telco-kpis-common-functions.sh"

# if [ -f "${SHARED_DIR}/skip.txt" ]; then
#   echo "Detected skip.txt — skipping"
#   exit 0
# fi

export_env_vars_from_json 'generate_report' "${REPORTING_SETTINGS:-}" "${REPORTING_SETTINGS_DEFAULTS:-}"
export_env_vars_from_json 'splunk' "${REPORTING_SETTINGS:-}" "${REPORTING_SETTINGS_DEFAULTS:-}"
setup_continue_on_fail
setup_debug_on_fail

main() {
    echo "Generating report for spoke: ${SPOKE_CLUSTER}"

    setup_ansible_inventory "${SPOKE_CLUSTER}" "${HUB_CLUSTER}"

    TIMESTAMP=$(date -u +%Y%m%d-%H%M%S)

    if [[ -z "${OUTPUT_FILENAME}" ]]; then
        OUTPUT_FILENAME="telco-kpis-report-${SPOKE_CLUSTER}-${TIMESTAMP}.md"
        echo "Auto-generated output filename: ${OUTPUT_FILENAME}"
    fi

    cd /eco-ci-cd

    DEBUG_FLAG=""
    if [ "${DEBUG}" = "true" ]; then
        DEBUG_FLAG="-vvv"
    fi

    FILTER_FLAG=()
    if [[ -n "${TEST_FILTER}" ]]; then
        FILTER_FLAG=(-e "test_filter=${TEST_FILTER}")
    fi

    # If rotating splunk_hec_token or git_repo_token, also update the
    # hypervisor vaults (teams/telco-kpis/hypervisors/) to keep Jenkins in sync.

    SPLUNK_FLAG=()
    if [ "${PUSH_ENABLED:-false}" = "true" ]; then
        SPLUNK_FLAG=(-e splunk_push_enabled=true)
        if [ -f /var/splunk/splunk_hec_token ]; then
            [[ $- == *x* ]] && _was_tracing=true || _was_tracing=false
            set +x
            SPLUNK_FLAG+=(-e "splunk_hec_url=${HEC_URL}")
            SPLUNK_FLAG+=(-e "splunk_hec_token=$(cat /var/splunk/splunk_hec_token)")
            $_was_tracing && set -x
        else
            echo "WARNING: Splunk push enabled but splunk_hec_token not found at /var/splunk/"
            SPLUNK_FLAG=()
        fi
        if [ ${#SPLUNK_FLAG[@]} -gt 0 ]; then
            SPLUNK_FLAG+=(-e "formal_test=${FORMAL_TEST:-false}")
            SPLUNK_FLAG+=(-e splunk_ci_type=prow)
            SPLUNK_FLAG+=(-e "splunk_ci_job_name=${JOB_NAME:-unknown}")
            SPLUNK_FLAG+=(-e "splunk_ci_build_number=${BUILD_ID:-unknown}")
        fi
    fi

    REPORT_REPO_FLAG=()
    if [ "${DEVELOPMENT_MODE}" != "true" ] && [ -n "${REPORT_REPO_URL:-}" ]; then
        REPORT_REPO_FLAG=(-e "report_repo_url=${REPORT_REPO_URL}")
        REPORT_REPO_FLAG+=(-e "report_repo_branch=${REPORT_REPO_BRANCH:-telco-kpis-reports}")
        if [ -f /var/reports-repo/git_repo_token ]; then
            [[ $- == *x* ]] && _was_tracing=true || _was_tracing=false
            set +x
            REPORT_REPO_FLAG+=(-e "report_repo_token=$(cat /var/reports-repo/git_repo_token)")
            $_was_tracing && set -x
        else
            echo "WARNING: Production report repo URL set but token not found at /var/reports-repo/git_repo_token"
            REPORT_REPO_FLAG=()
        fi
    fi

    FORCE_REPORT_FLAG=()
    if [ "${FORCE_REPORT:-false}" = "true" ]; then
        FORCE_REPORT_FLAG=(-e force_report=true)
    fi

    echo "Running generate-report playbook (development_mode: ${DEVELOPMENT_MODE}, splunk: ${PUSH_ENABLED:-false}, report_repo: ${REPORT_REPO_URL:-none}, force: ${FORCE_REPORT:-false})"
    ansible-playbook ./playbooks/telco-kpis/generate-report.yml \
        -i ./inventories/ocp-deployment/build-inventory.py \
        -e spoke_cluster="${SPOKE_CLUSTER}" \
        -e output_filename="${OUTPUT_FILENAME}" \
        -e timestamp="${TIMESTAMP}" \
        -e development_mode="${DEVELOPMENT_MODE}" \
        "${FILTER_FLAG[@]}" \
        "${SPLUNK_FLAG[@]}" \
        "${REPORT_REPO_FLAG[@]}" \
        "${FORCE_REPORT_FLAG[@]}" \
        ${DEBUG_FLAG}

    echo "Report generation completed for ${SPOKE_CLUSTER}"
}

main
