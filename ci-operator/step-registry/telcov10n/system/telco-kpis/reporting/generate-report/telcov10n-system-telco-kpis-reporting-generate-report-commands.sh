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

# Generate a telco-kpis Markdown report for a spoke cluster.
# Aggregates test artifacts, optionally publishes to a git repo
# and pushes results to Splunk. Sensitive credentials (tokens, URLs)
# are passed via a temporary vars file to avoid leaking into logs.
_yaml_quote() { local v="${1//\\/\\\\}"; v="${v//\"/\\\"}"; printf '%s' "$v"; }

main() {
    [[ $- == *x* ]] && _was_tracing=true || _was_tracing=false

    # Normalize and validate the publication mode early. Assigning the default
    # here ensures all later references to $REPORT_PUBLISH_MODE are consistent
    # (a bare case ":-prod" would only apply the default for that expression).
    REPORT_PUBLISH_MODE="${REPORT_PUBLISH_MODE:-prod}"
    case "${REPORT_PUBLISH_MODE}" in
        prod|dev-bastion|dev-hypervisor) ;;
        *)
            echo "ERROR: unsupported REPORT_PUBLISH_MODE '${REPORT_PUBLISH_MODE}'; must be prod, dev-bastion, or dev-hypervisor" >&2
            return 1
            ;;
    esac

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

    FORCE_REPORT_FLAG=()
    if [ "${FORCE_REPORT:-false}" = "true" ]; then
        FORCE_REPORT_FLAG=(-e force_report=true)
    fi

    # Write sensitive credentials to a temporary extra-vars file so they
    # never appear in command-line expansions or xtrace output.
    # If rotating splunk_hec_token or git_repo_token, also update the
    # hypervisor vaults (teams/telco-kpis/hypervisors/) to keep Jenkins in sync.
    SENSITIVE_VARS_FILE=$(mktemp /tmp/sensitive-vars-XXXXXX.yml)
    trap 'rm -f "${SENSITIVE_VARS_FILE}"' EXIT
    echo "---" > "${SENSITIVE_VARS_FILE}"

    SPLUNK_FLAG=()
    if [ "${PUSH_ENABLED:-false}" = "true" ]; then
        SPLUNK_FLAG=(-e splunk_push_enabled=true)
        if [ -z "${HEC_URL:-}" ]; then
            echo "WARNING: HEC_URL is unset or empty; Splunk push will likely fail"
        fi
        if [ -f /var/splunk/splunk_hec_token ]; then
            set +x
            {
                echo "splunk_hec_url: \"$(_yaml_quote "${HEC_URL:-}")\""
                echo "splunk_hec_token: \"$(_yaml_quote "$(cat /var/splunk/splunk_hec_token)")\""
            } >> "${SENSITIVE_VARS_FILE}"
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

    _has_report_repo=false
    if [ "${REPORT_PUBLISH_MODE}" = "prod" ] && [ -n "${REPORT_REPO_URL:-}" ]; then
        if [ -f /var/reports-repo/git_repo_token ]; then
            set +x
            {
                echo "report_repo_url: \"$(_yaml_quote "${REPORT_REPO_URL}")\""
                echo "report_repo_branch: \"$(_yaml_quote "${REPORT_REPO_BRANCH:-telco-kpis-reports}")\""
                echo "report_repo_token: \"$(_yaml_quote "$(cat /var/reports-repo/git_repo_token)")\""
            } >> "${SENSITIVE_VARS_FILE}"
            $_was_tracing && set -x
            _has_report_repo=true
        else
            echo "WARNING: Production report repo URL set but token not found at /var/reports-repo/git_repo_token"
        fi
    fi

    # Always forward git_repo_token so the playbook can derive kpi_targets_token
    # for fetching live KPI thresholds from GitLab — required even in development_mode
    # where the report-repo block above is skipped.
    if [ -f /var/reports-repo/git_repo_token ]; then
        set +x
        echo "git_repo_token: \"$(_yaml_quote "$(cat /var/reports-repo/git_repo_token)")\"" >> "${SENSITIVE_VARS_FILE}"
        $_was_tracing && set -x
    else
        echo "WARNING: /var/reports-repo/git_repo_token not found — KPI targets will use hardcoded fallback"
    fi

    if [ -n "${DEBUG_FLAG}" ] && [ "$(wc -l < "${SENSITIVE_VARS_FILE}")" -gt 1 ]; then
        echo "WARNING: -vvv is active with sensitive credentials in vars file; ensure tasks use no_log: true"
    fi

    echo "Running generate-report playbook (report_publish_mode: ${REPORT_PUBLISH_MODE}, splunk: ${PUSH_ENABLED:-false}, report_repo: ${_has_report_repo}, force: ${FORCE_REPORT:-false})"

    # Secrets are already in SENSITIVE_VARS_FILE (written under set +x above);
    # the command line only passes the file path, so tracing is safe here.
    ansible-playbook ./playbooks/telco-kpis/generate-report.yml \
        -i ./inventories/ocp-deployment/build-inventory.py \
        -e spoke_cluster="${SPOKE_CLUSTER}" \
        -e output_filename="${OUTPUT_FILENAME}" \
        -e timestamp="${TIMESTAMP}" \
        -e report_publish_mode="${REPORT_PUBLISH_MODE}" \
        -e "@${SENSITIVE_VARS_FILE}" \
        "${FILTER_FLAG[@]}" \
        "${SPLUNK_FLAG[@]}" \
        "${FORCE_REPORT_FLAG[@]}" \
        ${DEBUG_FLAG}

    echo "Report generation completed for ${SPOKE_CLUSTER}"
}

main
