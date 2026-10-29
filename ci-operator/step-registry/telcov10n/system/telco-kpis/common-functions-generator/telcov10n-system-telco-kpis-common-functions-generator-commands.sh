#!/bin/bash
set -euo pipefail

echo "Generating telco-kpis shared functions..."

cat << 'EOF' > "${SHARED_DIR}/telco-kpis-common-functions.sh"
########################################################################
# Telco-KPIs shared functions for Prow steps
########################################################################

# Prow runs containers with arbitrary UIDs and HOME=/ (not writable).
# Ansible resolves ~/.ansible/tmp via /etc/passwd, not $HOME, for delegate_to: localhost tasks.
export ANSIBLE_REMOTE_TMP=/tmp/.ansible/tmp

MOUNTED_HOST_INVENTORY="/var/host_variables"
MOUNTED_GROUP_INVENTORY="/var/group_variables"

# ----------------------------------------------------------------------
# apply_gangway_overrides
#
# Applies Gangway API overrides for job parameters. This function MUST be
# called AFTER export_env_vars_from_json to ensure Gangway overrides have
# the highest precedence (JSON settings < Gangway overrides).
#
# When triggering jobs via Gangway API, environment variables can be
# overridden using the MULTISTAGE_PARAM_OVERRIDE_* prefix. This function
# checks for those overrides and applies them, overwriting any values
# that came from INFRA_SETTINGS or TEST_SETTINGS JSON.
#
# Supported overrides:
#   MULTISTAGE_PARAM_OVERRIDE_HUB_CLUSTER -> HUB_CLUSTER
#   MULTISTAGE_PARAM_OVERRIDE_SPOKE_CLUSTER -> SPOKE_CLUSTER
#   MULTISTAGE_PARAM_OVERRIDE_DURATION -> DURATION
#   MULTISTAGE_PARAM_OVERRIDE_HUB_LOCKDOWN_URI -> HUB_LOCKDOWN_URI
#   MULTISTAGE_PARAM_OVERRIDE_LOCKDOWN_URI -> LOCKDOWN_URI + SPOKE_LOCKDOWN_URI
#   MULTISTAGE_PARAM_OVERRIDE_OCP_RELEASE_IMAGE -> OCP_RELEASE_IMAGE
#   MULTISTAGE_PARAM_OVERRIDE_ZTP_GIT_BRANCH -> ZTP_GIT_BRANCH
#   MULTISTAGE_PARAM_OVERRIDE_REPORT_HEADLINE -> REPORT_HEADLINE
#   MULTISTAGE_PARAM_OVERRIDE_REBOOT_COUNT -> REBOOT_COUNT
#   MULTISTAGE_PARAM_OVERRIDE_BASELINE -> BASELINE
#   MULTISTAGE_PARAM_OVERRIDE_TEST_OPTIONS -> TEST_OPTIONS
#   MULTISTAGE_PARAM_OVERRIDE_RDS_REFERENCE_BRANCH -> REFERENCE_BRANCH
#   MULTISTAGE_PARAM_OVERRIDE_THRESHOLD_DURATION -> THRESHOLD_DURATION
#   MULTISTAGE_PARAM_OVERRIDE_REPORT_PUBLISH_MODE -> REPORT_PUBLISH_MODE
#   MULTISTAGE_PARAM_OVERRIDE_FORMAL_TEST -> FORMAL_TEST
#
# Step-specific overrides (handled in individual step scripts before calling this function):
#   MULTISTAGE_PARAM_OVERRIDE_SPOKE_SKIP_PUSH_TO_DATA_LAKE (push-to-data-lake only)
# ----------------------------------------------------------------------

apply_gangway_overrides() {
    if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_HUB_CLUSTER:-}" ]]; then
        export HUB_CLUSTER="${MULTISTAGE_PARAM_OVERRIDE_HUB_CLUSTER}"
        echo "Using Gangway override: HUB_CLUSTER=${HUB_CLUSTER}"
    fi

    if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_SPOKE_CLUSTER:-}" ]]; then
        export SPOKE_CLUSTER="${MULTISTAGE_PARAM_OVERRIDE_SPOKE_CLUSTER}"
        echo "Using Gangway override: SPOKE_CLUSTER=${SPOKE_CLUSTER}"
    fi

    if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_DURATION:-}" ]]; then
        export DURATION="${MULTISTAGE_PARAM_OVERRIDE_DURATION}"
        echo "Using Gangway override: DURATION=${DURATION}"
    fi

    if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_HUB_LOCKDOWN_URI:-}" ]]; then
        export HUB_LOCKDOWN_URI="${MULTISTAGE_PARAM_OVERRIDE_HUB_LOCKDOWN_URI}"
        echo "Using Gangway override: HUB_LOCKDOWN_URI=${HUB_LOCKDOWN_URI}"
    fi

    if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_LOCKDOWN_URI:-}" ]]; then
        export LOCKDOWN_URI="${MULTISTAGE_PARAM_OVERRIDE_LOCKDOWN_URI}"
        export SPOKE_LOCKDOWN_URI="${MULTISTAGE_PARAM_OVERRIDE_LOCKDOWN_URI}"
        echo "Using Gangway override: LOCKDOWN_URI=${LOCKDOWN_URI}"
        echo "Using Gangway override: SPOKE_LOCKDOWN_URI=${SPOKE_LOCKDOWN_URI}"
    fi

    if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_OCP_RELEASE_IMAGE:-}" ]]; then
        export OCP_RELEASE_IMAGE="${MULTISTAGE_PARAM_OVERRIDE_OCP_RELEASE_IMAGE}"
        echo "Using Gangway override: OCP_RELEASE_IMAGE=${OCP_RELEASE_IMAGE}"
    fi

    if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_ZTP_GIT_BRANCH:-}" ]]; then
        export ZTP_GIT_BRANCH="${MULTISTAGE_PARAM_OVERRIDE_ZTP_GIT_BRANCH}"
        echo "Using Gangway override: ZTP_GIT_BRANCH=${ZTP_GIT_BRANCH}"
    fi

    if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_REPORT_HEADLINE:-}" ]]; then
        export REPORT_HEADLINE="${MULTISTAGE_PARAM_OVERRIDE_REPORT_HEADLINE}"
        echo "Using Gangway override: REPORT_HEADLINE=${REPORT_HEADLINE}"
    fi

    if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_REBOOT_COUNT:-}" ]]; then
        export REBOOT_COUNT="${MULTISTAGE_PARAM_OVERRIDE_REBOOT_COUNT}"
        echo "Using Gangway override: REBOOT_COUNT=${REBOOT_COUNT}"
    fi

    if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_BASELINE:-}" ]]; then
        export BASELINE="${MULTISTAGE_PARAM_OVERRIDE_BASELINE}"
        echo "Using Gangway override: BASELINE=${BASELINE}"
    fi

    if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_TEST_OPTIONS:-}" ]]; then
        export TEST_OPTIONS="${MULTISTAGE_PARAM_OVERRIDE_TEST_OPTIONS}"
        echo "Using Gangway override: TEST_OPTIONS=${TEST_OPTIONS}"
    fi

    if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_RDS_REFERENCE_BRANCH:-}" ]]; then
        export REFERENCE_BRANCH="${MULTISTAGE_PARAM_OVERRIDE_RDS_REFERENCE_BRANCH}"
        echo "Using Gangway override: REFERENCE_BRANCH=${REFERENCE_BRANCH}"
    fi

    if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_THRESHOLD_DURATION:-}" ]]; then
        export THRESHOLD_DURATION="${MULTISTAGE_PARAM_OVERRIDE_THRESHOLD_DURATION}"
        echo "Using Gangway override: THRESHOLD_DURATION=${THRESHOLD_DURATION}"
    fi

    if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_REPORT_PUBLISH_MODE:-}" ]]; then
        export REPORT_PUBLISH_MODE="${MULTISTAGE_PARAM_OVERRIDE_REPORT_PUBLISH_MODE}"
        echo "Using Gangway override: REPORT_PUBLISH_MODE=${REPORT_PUBLISH_MODE}"
    fi

    if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_FORMAL_TEST:-}" ]]; then
        export FORMAL_TEST="${MULTISTAGE_PARAM_OVERRIDE_FORMAL_TEST}"
        echo "Using Gangway override: FORMAL_TEST=${FORMAL_TEST}"
    fi
}

# ----------------------------------------------------------------------
# skip_via_gangway_overrides
#
# Checks step-specific MULTISTAGE_PARAM_OVERRIDE_*_SKIP_* variables and
# handles skip behavior with absolute precedence over JSON config.
#
# This function MUST be called BEFORE export_env_vars_from_json.
#
# Currently supported overrides:
#   - MULTISTAGE_PARAM_OVERRIDE_SPOKE_SKIP_PUSH_TO_DATA_LAKE (push-to-data-lake)
#     - If "true": Skip step immediately (exit 0)
#     - If "false": Force-enable by removing skip from REPORTING_SETTINGS JSON
#     - If not defined: Continue (use skip from JSON)
#
# Future overrides can be added here for other steps.
# ----------------------------------------------------------------------

skip_via_gangway_overrides() {
    # Check push-to-data-lake skip override
    if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_SPOKE_SKIP_PUSH_TO_DATA_LAKE:-}" ]]; then
        if [[ "${MULTISTAGE_PARAM_OVERRIDE_SPOKE_SKIP_PUSH_TO_DATA_LAKE}" == "true" ]]; then
            echo "SKIPPED: step — MULTISTAGE_PARAM_OVERRIDE_SPOKE_SKIP_PUSH_TO_DATA_LAKE=true"
            exit 0
        elif [[ "${MULTISTAGE_PARAM_OVERRIDE_SPOKE_SKIP_PUSH_TO_DATA_LAKE}" == "false" ]]; then
            echo "MULTISTAGE_PARAM_OVERRIDE_SPOKE_SKIP_PUSH_TO_DATA_LAKE=false — forcing step to run"
            REPORTING_SETTINGS=$(printf '%s' "${REPORTING_SETTINGS:-}" | python3 -c "
import json, sys
raw = sys.stdin.read().strip()
settings = json.loads(raw) if raw else {}
if 'push_to_data_lake' in settings and 'skip' in settings['push_to_data_lake']:
    del settings['push_to_data_lake']['skip']
print(json.dumps(settings))
")
            export REPORTING_SETTINGS
        fi
    fi

    # Future MULTISTAGE skip overrides can be checked here
}

# ======================================================================
# UNIFIED EXIT HANDLER FRAMEWORK
# ======================================================================
# Global state for cleanup handlers (per-script registration)
_EXIT_CLEANUP_HANDLERS=()

# ----------------------------------------------------------------------
# add_cleanup_handler
#
# Registers a cleanup function to be executed on script exit (success or
# failure). Cleanup handlers run in LIFO order (last registered, first
# executed) before any exit logic (debug, continue_on_fail).
#
# Use cases:
#   - Release distributed locks (deploy-vm-bastion)
#   - Remove temporary credential files (generate-report, push-to-data-lake)
#   - Collect artifacts from /artifacts/ to ARTIFACT_DIR/SHARED_DIR
#
# Parameters:
#   1 - handler_function: Name of the function to call on EXIT
#
# Usage:
#   _gather_artifacts() { cp /artifacts/*.json "${ARTIFACT_DIR}/" || true; }
#   add_cleanup_handler _gather_artifacts
# ----------------------------------------------------------------------

add_cleanup_handler() {
    local handler="$1"
    _EXIT_CLEANUP_HANDLERS+=("${handler}")
}

# ----------------------------------------------------------------------
# __telco_kpis_exit_handler (INTERNAL)
#
# Unified exit handler that runs ALL exit logic for telco-kpis steps.
# This function should NEVER be called directly - it is installed by
# setup_telco_kpis_exit_handler() as the EXIT trap.
#
# Execution phases:
#   1. CLEANUP: Runs all registered cleanup handlers (always, regardless of exit code)
#   2. EXIT LOGIC: Determines exit behavior based on priority:
#      - Priority 1: CONTINUE_ON_FAIL (dev override: force exit 0 on error)
#      - Priority 2: DEBUG_ON_FAIL (PR debugging: wait loop on error)
#      - Priority 3: Natural exit (default: exit with original code)
#
# Critical: Preserves original exit code through all cleanup operations
# so DEBUG_ON_FAIL and downstream tools get the correct exit status.
# ----------------------------------------------------------------------

__telco_kpis_exit_handler() {
    # CRITICAL: Capture original exit code IMMEDIATELY before any operations
    local original_exit_code=$?

    # --- PHASE 1: CLEANUP (Always runs, regardless of exit code) ---
    if [[ ${#_EXIT_CLEANUP_HANDLERS[@]} -gt 0 ]]; then
        echo "=========================================="
        echo "Running ${#_EXIT_CLEANUP_HANDLERS[@]} cleanup handler(s)..."
        echo "=========================================="

        # Run in reverse order (LIFO: last registered, first executed)
        # This ensures artifacts are gathered before temp files are removed
        for ((i=${#_EXIT_CLEANUP_HANDLERS[@]}-1; i>=0; i--)); do
            local handler="${_EXIT_CLEANUP_HANDLERS[i]}"
            echo "→ Running cleanup: ${handler}"
            ${handler} || echo "  WARNING: Cleanup handler '${handler}' failed (continuing)"
        done

        echo "Cleanup phase complete"
        echo "=========================================="
    fi

    # --- PHASE 2: EXIT LOGIC (Priority order) ---

    # Priority 1: CONTINUE_ON_FAIL (development override - highest priority)
    # When enabled, forces exit 0 on any error to continue the pipeline.
    # Used for development/debugging - NOT for production runs.
    if [[ "${CONTINUE_ON_FAIL:-false}" == "true" ]] && [[ ${original_exit_code} -ne 0 ]]; then
        echo "CONTINUE_ON_FAIL enabled — test failed (exit code ${original_exit_code}) but forcing exit 0"
        exit 0
    fi

    # Priority 2: DEBUG_ON_FAIL (interactive debugging in PRs)
    # When enabled in PR runs, enters a wait loop on failure to allow
    # interactive debugging in the pod terminal. Preserves original exit
    # code so failure is still reported after debug timeout.
    if [[ "${DEBUG_ON_FAIL:-false}" == "true" ]] && [[ -n "${PULL_NUMBER:-}" ]] && [[ ${original_exit_code} -ne 0 ]]; then
        echo
        echo "################################################################################"
        echo "# PR ${PULL_NUMBER} — Step failed (exit code ${original_exit_code}). Entering debug mode..."
        echo "################################################################################"

        TZ=UTC
        local end_time
        end_time=$(date -d "${DEBUG_TIMEOUT:-+10 min}" +%s)
        local debug_done=/tmp/debug.done
        local keep_debugging=/tmp/keep.debugging

        while sleep 1m; do
            [[ -f "${debug_done}" ]] && break
            echo
            echo "-------------------------------------------------------------------"
            echo "'${debug_done}' not found. Debugging can continue..."
            local now
            now=$(date +%s)
            if [[ "${end_time}" -lt "${now}" ]]; then
                if [[ -f "${keep_debugging}" ]]; then
                    echo "To quit debugging: rm -f ${keep_debugging}"
                    continue
                else
                    echo "Timeout reached. Exiting debug mode..."
                    break
                fi
            else
                echo "Now:     $(date -d "@${now}")"
                echo "Timeout: $(date -d "@${end_time}")"
            fi
            echo "[Note]:"
            echo "- To exit debug mode early: touch ${debug_done}"
            echo "- To extend past timeout:   touch ${keep_debugging}"
        done

        echo
        echo "Exiting debug mode with original exit code: ${original_exit_code}"
        exit ${original_exit_code}
    fi

    # Priority 3: Natural exit (default)
    # Exit with the original exit code from the script/playbook/test.
    # No special behavior - standard Prow step exit.
    exit ${original_exit_code}
}

# ----------------------------------------------------------------------
# setup_telco_kpis_exit_handler
#
# Installs the unified exit handler for the current script. This function
# should be called ONCE at the start of main() in each telco-kpis step.
#
# The unified handler provides:
#   - Guaranteed cleanup execution (locks, credentials, artifacts)
#   - CONTINUE_ON_FAIL support (development override)
#   - DEBUG_ON_FAIL support (PR debugging)
#   - Correct exit code preservation through all cleanup
#
# Usage:
#   main() {
#       setup_telco_kpis_exit_handler  # Install unified handler FIRST
#
#       # Register cleanup handlers (script-specific)
#       add_cleanup_handler _cleanup_sensitive_vars
#       add_cleanup_handler _gather_artifacts
#
#       # Do work...
#   }
# ----------------------------------------------------------------------

setup_telco_kpis_exit_handler() {
    trap '__telco_kpis_exit_handler' EXIT
}

# ======================================================================
# DEPRECATED FUNCTIONS (Backwards Compatibility)
# ======================================================================
# The functions below are kept for backwards compatibility with existing
# scripts. New scripts should use:
#   - setup_telco_kpis_exit_handler() instead of setup_debug_on_fail/setup_continue_on_fail
#   - add_cleanup_handler() instead of add_exit_handler()
# ======================================================================

# ----------------------------------------------------------------------
# add_exit_handler (DEPRECATED)
#
# Legacy function - redirects to add_cleanup_handler for backwards compatibility.
# Automatically installs the unified handler if not already installed.
# Use add_cleanup_handler() in new code.
# ----------------------------------------------------------------------

add_exit_handler() {
    _ensure_unified_handler_installed
    add_cleanup_handler "$1"
}

# Internal helper to ensure unified handler is installed (for backwards compat)
_ensure_unified_handler_installed() {
    # Check if our unified handler is already installed
    local current_trap
    current_trap=$(trap -p EXIT | sed "s/trap -- '\(.*\)' EXIT/\1/")

    if [[ "${current_trap}" != "__telco_kpis_exit_handler" ]]; then
        setup_telco_kpis_exit_handler
    fi
}

# ----------------------------------------------------------------------
# setup_direct_ssh
#
# Configures direct SSH to a bastion host. Appends
# ansible_ssh_common_args, ansible_ssh_private_key_file, and
# ansible_remote_tmp to the host_vars file.
#
# Parameters:
#   1 - mounted_host_inventory: path to host variables mount (unused, kept for compat)
#   2 - mounted_group_inventory: path to group variables mount
#   3 - host_vars_file: path to host_vars file to append to
# ----------------------------------------------------------------------

setup_direct_ssh() {
    local mounted_host_inventory="$1"
    local mounted_group_inventory="$2"
    local host_vars_file="$3"

    local ssh_key_file="/tmp/ssh-direct-key"
    [[ $- == *x* ]] && local was_tracing=true || local was_tracing=false
    set +x
    cat "${mounted_group_inventory}/common/all/ansible_ssh_private_key" > "${ssh_key_file}"
    $was_tracing && set -x
    chmod 600 "${ssh_key_file}"

    python3 -c "
import yaml, sys

key = 'ansible_ssh_common_args'
ssh_opts = (
    '-o StrictHostKeyChecking=no '
    '-o UserKnownHostsFile=/dev/null '
    '-o ServerAliveInterval=60 '
    '-o ServerAliveCountMax=720'
)
print(yaml.dump({key: ssh_opts}, default_flow_style=False, allow_unicode=True).rstrip())
" >> "${host_vars_file}"

    echo "ansible_ssh_private_key_file: ${ssh_key_file}" >> "${host_vars_file}"

    echo "ansible_remote_tmp: ~/.ansible/tmp" >> "${host_vars_file}"

    echo "Direct SSH configured for: $(basename "${host_vars_file}")"
}

# ----------------------------------------------------------------------
# process_inventory
#
# Reads Kubernetes secret mount files from a directory and serializes
# each as a YAML key-value pair into a destination file, using Python
# yaml.dump for correct escaping of multi-line values and quotes.
#
# Parameters:
#   1 - directory: source directory containing secret mount files
#   2 - dest_file: destination file to write YAML key-value pairs
# ----------------------------------------------------------------------

process_inventory() {
    local directory="$1"
    local dest_file="$2"

    if [ -z "$directory" ]; then
        echo "Usage: process_inventory <directory> <dest_file>"
        return 1
    fi

    if [ ! -d "$directory" ]; then
        echo "Error: '$directory' is not a valid directory"
        return 1
    fi

    : > "${dest_file}"

    find "$directory" -type f | while IFS= read -r filename; do
        if [[ $filename == *"secretsync-vault-source-path"* ]]; then
          continue
        fi

        key=$(basename "${filename}")
        python3 -c "
import yaml
import sys

key = sys.argv[1]
with open(sys.argv[2], 'r') as f:
    value = f.read()

print(yaml.dump({key: value}, default_flow_style=False, allow_unicode=True).rstrip())
" "$key" "$filename" >> "${dest_file}"
    done

    echo "Processing complete. Check \"${dest_file}\""
}

# ----------------------------------------------------------------------
# setup_ansible_inventory
#
# Sets up the complete Ansible inventory from Kubernetes secret mounts:
#   1. Creates group_vars from common and spoke-specific group variables
#   2. Creates host_vars from spoke and hub bastion credentials
#   3. Configures direct SSH to hub bastion
#
# Parameters:
#   1 - spoke_cluster: spoke cluster name (e.g., spree-02)
#   2 - hub_cluster: hub cluster name (e.g., kni-qe-71)
# ----------------------------------------------------------------------

setup_ansible_inventory() {
    local spoke_cluster="$1"
    local hub_cluster="$2"

    echo "Setting up Ansible inventory for spoke: ${spoke_cluster}, hub: ${hub_cluster}"

    echo "Create group_vars directory"
    mkdir -p /eco-ci-cd/inventories/ocp-deployment/group_vars

    # Process common group variables
    find "${MOUNTED_GROUP_INVENTORY}/common/" -mindepth 1 -type d | while read -r dir; do
        echo "Process common group inventory file: ${dir}"
        process_inventory "$dir" /eco-ci-cd/inventories/ocp-deployment/group_vars/"$(basename "${dir}")"
    done

    # Process spoke-specific group variables
    if [[ -d "${MOUNTED_GROUP_INVENTORY}/${spoke_cluster}" ]]; then
        find "${MOUNTED_GROUP_INVENTORY}/${spoke_cluster}/" -mindepth 1 -type d | while read -r dir; do
            echo "Process spoke group inventory file: ${dir}"
            process_inventory "$dir" /eco-ci-cd/inventories/ocp-deployment/group_vars/"$(basename "${dir}")"
        done
    fi

    echo "Create host_vars directory"
    mkdir -p /eco-ci-cd/inventories/ocp-deployment/host_vars

    # Process hypervisor host variables so plays targeting [hypervisor] can resolve the real IP.
    # No setup_direct_ssh here — group_vars/hypervisors provides the SSH key.
    if [[ -d "${MOUNTED_HOST_INVENTORY}/common/hypervisor" ]]; then
        echo "Process hypervisor host inventory"
        process_inventory "${MOUNTED_HOST_INVENTORY}/common/hypervisor" \
            /eco-ci-cd/inventories/ocp-deployment/host_vars/hypervisor
    fi

    # Copy spoke credentials to temporary location
    mkdir -p /tmp/"${spoke_cluster}" && chmod 700 /tmp/"${spoke_cluster}"

    # Copy spoke-specific credentials (master0, etc.)
    if [[ -d "${MOUNTED_HOST_INVENTORY}/${spoke_cluster}" ]]; then
        cp -r "${MOUNTED_HOST_INVENTORY}/${spoke_cluster}/"* /tmp/"${spoke_cluster}"/
    fi
    ls -l /tmp/"${spoke_cluster}"/

    # Process spoke host variables
    find /tmp/"${spoke_cluster}"/ -mindepth 1 -type d | while read -r dir; do
        echo "Process spoke host inventory file: ${dir}"
        process_inventory "$dir" /eco-ci-cd/inventories/ocp-deployment/host_vars/"$(basename "${dir}")"
    done

    # Process hub host credentials and configure direct SSH.
    if [[ -d "${MOUNTED_HOST_INVENTORY}/${hub_cluster}" ]]; then
        for hub_host_dir in "${MOUNTED_HOST_INVENTORY}/${hub_cluster}/"*/; do
            [[ -d "${hub_host_dir}" ]] || continue
            local hub_host_name
            hub_host_name=$(basename "${hub_host_dir}")
            local hub_host_vars_file
            hub_host_vars_file="/eco-ci-cd/inventories/ocp-deployment/host_vars/${hub_host_name}"

            if [[ -f "${hub_host_vars_file}" ]] && [[ "${spoke_cluster}" != "${hub_cluster}" ]]; then
                echo "ERROR: host_vars collision — hub '${hub_cluster}' host '${hub_host_name}' would overwrite spoke '${spoke_cluster}' host_vars"
                return 1
            fi

            echo "Process hub host inventory: ${hub_host_name}"
            process_inventory "${hub_host_dir}" "${hub_host_vars_file}"
            setup_direct_ssh "${MOUNTED_HOST_INVENTORY}" "${MOUNTED_GROUP_INVENTORY}" \
                "${hub_host_vars_file}"
        done
    fi

    echo "Ansible inventory setup complete"
}

# ----------------------------------------------------------------------
# setup_infra_inventory
#
# Sets up Ansible inventory for infrastructure playbooks that use the
# inventories/infra/ layout (bastion + hypervisor hosts). This is
# distinct from setup_ansible_inventory which uses inventories/ocp-deployment/.
#
# Populates group_vars (all, bastions, hypervisors) and host_vars
# (hypervisor, bastion) from Kubernetes secret mounts, then configures
# direct SSH to the bastion. The hypervisor host_vars
# are processed if present but skipped for SSH configuration.
#
# Parameters:
#   1 - hub_cluster: hub cluster name (e.g., kni-qe-70) — used to
#       locate the bastion host_vars at /var/host_variables/<hub_cluster>/bastion
# ----------------------------------------------------------------------

setup_infra_inventory() {
    local hub_cluster="$1"

    echo "Setting up infra inventory for hub: ${hub_cluster}"

    local infra_inv="/eco-ci-cd/inventories/infra"

    echo "Create group_vars directory"
    mkdir -p "${infra_inv}/group_vars"

    for group_dir in "${MOUNTED_GROUP_INVENTORY}/common/"*/; do
        if [[ -d "${group_dir}" ]]; then
            local group_name
            group_name=$(basename "${group_dir}")
            echo "Process infra group inventory: ${group_name}"
            process_inventory "${group_dir}" "${infra_inv}/group_vars/${group_name}"
        fi
    done

    echo "Create host_vars directory"
    mkdir -p "${infra_inv}/host_vars"

    if [[ -d "${MOUNTED_HOST_INVENTORY}/common/hypervisor" ]]; then
        echo "Process hypervisor host inventory"
        process_inventory "${MOUNTED_HOST_INVENTORY}/common/hypervisor" \
            "${infra_inv}/host_vars/hypervisor"
    fi

    if [[ -d "${MOUNTED_HOST_INVENTORY}/${hub_cluster}/bastion" ]]; then
        echo "Process bastion host inventory for hub: ${hub_cluster}"
        process_inventory "${MOUNTED_HOST_INVENTORY}/${hub_cluster}/bastion" \
            "${infra_inv}/host_vars/bastion"
    fi

    for host_vars_file in "${infra_inv}"/host_vars/*; do
        [[ -f "${host_vars_file}" ]] || continue
        [[ "$(basename "${host_vars_file}")" == "hypervisor" ]] && continue
        echo "Configuring direct SSH for: $(basename "${host_vars_file}")"
        setup_direct_ssh "${MOUNTED_HOST_INVENTORY}" "${MOUNTED_GROUP_INVENTORY}" \
            "${host_vars_file}"
    done

    echo "Infra inventory setup complete"
}

# ----------------------------------------------------------------------
# export_env_vars_from_json
#
# Merges *_SETTINGS_DEFAULTS (ref-level) with *_SETTINGS (config-level)
# and exports the result as uppercase environment variables.
# *_SETTINGS values take precedence over *_SETTINGS_DEFAULTS.
# Supports "skip": true to skip a step and "continue_on_fail": true
# to prevent pipeline stops.
#
# IMPORTANT — shallow merge: overrides REPLACE entire keys, they do NOT
# deep-merge nested objects or append to arrays. For example, if defaults
# define a list of 13 images and the CI config overrides that key with a
# list of 1 image, the result is 1 image — not 14. To add an image,
# copy the full default list into the CI config override and append.
# This is why some defaults (e.g. ran_images) are left empty: putting a
# default list there would force every CI config to duplicate it in full
# just to add or remove a single entry.
#
# Dict/list values are serialized to JSON strings via json.dumps() when
# exported, so downstream consumers receive valid JSON.
#
# Parameters:
#   1 - step_testname: test key in the JSON (e.g., "oslat", "reboot")
#   2 - test_settings: config-level overrides JSON (defaults to empty)
#   3 - test_settings_defaults: ref-level defaults JSON (defaults to empty)
# ----------------------------------------------------------------------

export_env_vars_from_json() {
    local step_testname="$1"
    local test_settings="${2:-}"
    local test_settings_defaults="${3:-}"

    local result
    result=$(python3 -c "
import json, sys

step_name = sys.argv[1]
overrides_raw = sys.argv[2] if len(sys.argv) > 2 else ''
defaults_raw = sys.argv[3] if len(sys.argv) > 3 else ''

def parse_json(raw, label):
    if not raw or raw.strip() == '{}':
        return {}
    try:
        return json.loads(raw)
    except (json.JSONDecodeError, ValueError) as exc:
        print(f'ERROR: malformed JSON in {label}: {exc}', file=sys.stderr)
        sys.exit(1)

defaults_all = parse_json(defaults_raw, 'settings_defaults')
overrides_all = parse_json(overrides_raw, 'settings')

defaults = defaults_all.get(step_name, {})
overrides = overrides_all.get(step_name, {})

merged = {**defaults, **overrides}

if not merged:
    sys.exit(0)

has_overrides = bool(overrides)
print(f'__DUMP_START__')
print(f'Step: {step_name}')
if has_overrides:
    print(f'Defaults:  {json.dumps(defaults, indent=2)}')
    print(f'Overrides: {json.dumps(overrides, indent=2)}')
print(f'Merged:    {json.dumps(merged, indent=2)}')
print(f'__DUMP_END__')

skip_val = merged.get('skip', False)
if isinstance(skip_val, bool):
    is_skip = skip_val
else:
    is_skip = str(skip_val).lower() == 'true'

if is_skip:
    print('SKIP=true')
    sys.exit(0)

for key, value in merged.items():
    if key == 'skip':
        continue
    env_name = key.upper()
    if isinstance(value, bool):
        value = str(value).lower()
    elif isinstance(value, (dict, list)):
        value = json.dumps(value)
    print(f'{env_name}={value}')
" "${step_testname}" "${test_settings}" "${test_settings_defaults}")

    if [[ -z "${result}" ]]; then
        echo "No settings found for '${step_testname}'"
        return 0
    fi

    local dump
    dump=$(echo "${result}" | sed -n '/__DUMP_START__/,/__DUMP_END__/p' | grep -v '__DUMP_')
    local settings_lines
    settings_lines=$(echo "${result}" | sed '/__DUMP_START__/,/__DUMP_END__/d')

    if [[ -n "${dump}" ]]; then
        echo "========================================"
        echo "${dump}"
        echo "========================================"
    fi

    if echo "${settings_lines}" | grep -q "^SKIP=true$"; then
        echo "SKIPPED: ${step_testname} — skip=true in TEST_SETTINGS"
        exit 0
    fi

    if [[ -z "${settings_lines}" ]]; then
        return 0
    fi

    while IFS='=' read -r key value; do
        export "${key}=${value}"
    done <<< "${settings_lines}"
}

# ----------------------------------------------------------------------
# setup_continue_on_fail (DEPRECATED)
#
# Legacy function for backwards compatibility with existing scripts.
# Now handled by setup_telco_kpis_exit_handler() which checks CONTINUE_ON_FAIL.
#
# Automatically installs the unified handler if not already installed.
# New scripts should call setup_telco_kpis_exit_handler() directly.
# ----------------------------------------------------------------------

setup_continue_on_fail() {
    _ensure_unified_handler_installed

    if [[ "${CONTINUE_ON_FAIL:-false}" == "true" ]]; then
        echo "CONTINUE_ON_FAIL enabled — test failures will not stop the pipeline"
        # Still set -E for ERR trap inheritance (might be used elsewhere)
        set -E
    fi
}

# ----------------------------------------------------------------------
# setup_debug_on_fail (DEPRECATED)
#
# Legacy function for backwards compatibility with existing scripts.
# Now handled by setup_telco_kpis_exit_handler() which checks DEBUG_ON_FAIL.
#
# Automatically installs the unified handler if not already installed.
# New scripts should call setup_telco_kpis_exit_handler() directly.
# ----------------------------------------------------------------------

setup_debug_on_fail() {
    _ensure_unified_handler_installed

    if [[ "${DEBUG_ON_FAIL:-false}" != "true" ]]; then
        return 0
    fi
    if [[ -z "${PULL_NUMBER:-}" ]]; then
        echo "DEBUG_ON_FAIL enabled but not a PR run — will be skipped"
        return 0
    fi
    echo "DEBUG_ON_FAIL enabled — will enter debug mode on failure (PR ${PULL_NUMBER})"
}

# ----------------------------------------------------------------------
# resolve_ocp_version_from_lockdown
#
# Extracts the OCP version (X.Y) from a lockdown JSON URI by running
# the ocp-version-from-lockdown.yml Ansible playbook. Caches the result
# per URI tail in ${SHARED_DIR} so subsequent calls with the same URI
# return instantly.
#
# Parameters:
#   1 - lockdown_uri: URL to hub or spoke lockdown JSON
#
# Side effects:
#   - Writes ${SHARED_DIR}/ocp_version_from_<uri_tail>
#   - Exports VERSION with the extracted value so all downstream
#     code that references ${VERSION} gets the correct value
#
# Must be called AFTER setup_ansible_inventory (needs bastion SSH).
# ----------------------------------------------------------------------

resolve_ocp_version_from_lockdown() {
    local lockdown_uri="$1"
    local uri_tail
    uri_tail=$(basename "${lockdown_uri}" .json)
    local output_file="${SHARED_DIR}/ocp_version_from_${uri_tail}"

    if [[ -f "${output_file}" ]]; then
        VERSION=$(cat "${output_file}")
        export VERSION
        echo "OCP version (cached from ${uri_tail}): ${VERSION}"
        return 0
    fi

    pushd /eco-ci-cd > /dev/null

    ansible-playbook ./playbooks/telco-kpis/ocp-version-from-lockdown.yml \
        -i ./inventories/ocp-deployment/build-inventory.py \
        -e "lockdown_uri=${lockdown_uri}" \
        -e "ocp_version_output_file=${output_file}" \
        -vv

    popd > /dev/null

    VERSION=$(cat "${output_file}")
    export VERSION
    echo "OCP version extracted (${uri_tail}): ${VERSION}"
}
EOF

echo "Shared functions written to ${SHARED_DIR}/telco-kpis-common-functions.sh"
ls -l "${SHARED_DIR}/telco-kpis-common-functions.sh"
