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

COMMON_VARIABLES="/var/common_variables"
CLUSTER_VARIABLES="/var/clusters"
HYPERVISOR_VARIABLES="/var/hypervisors"

# ----------------------------------------------------------------------
# setup_direct_ssh
#
# Configures direct SSH to a host. Appends ansible_ssh_common_args,
# ansible_ssh_private_key_file, and ansible_remote_tmp to the host_vars
# file.
#
# Parameters:
#   1 - host_vars_file: path to host_vars file to append to
# ----------------------------------------------------------------------

setup_direct_ssh() {
    local host_vars_file="$1"

    local ssh_key_file="/tmp/ssh-direct-key"
    # The private key spans several lines in ansible_group_all, take everything
    # between the quotes. Create the file 0600 up front so it is never readable
    # by others, not even for the moment between writing it and chmod'ing it.
    install -m 600 /dev/null "${ssh_key_file}"
    sed -n "/^ansible_ssh_private_key: /,/'\$/p" "${COMMON_VARIABLES}/ansible_group_all" \
        | sed -e "s/^ansible_ssh_private_key: '//" -e "s/'\$//" > "${ssh_key_file}"

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
# install_vars
#
# Installs a single secret file from a GSM mount into the inventory.
# Each secret under a mounted group is exposed as one file holding a
# complete Ansible vars document, so installing it is a plain copy;
# only the destination has to be worked out from the secret name.
#
# Parameters:
#   1 - src: path to the mounted secret file
#   2 - inventory_path: inventory root holding group_vars/ and host_vars/
#   3 - allow_host_vars: "true" to also install non-group vars as host_vars
# ----------------------------------------------------------------------

install_vars() {
    local src="$1"
    local inventory_path="$2"
    local allow_host_vars="$3"
    local base dest_dir name

    base="$(basename "$src")"

    case "$base" in
        ansible_group_*)
            dest_dir="${inventory_path}/group_vars"
            name="${base#ansible_group_}"
            ;;
        *)
            if [ "${allow_host_vars}" != "true" ]; then
                echo "  skipped a file that is not a group var"
                return 0
            fi
            dest_dir="${inventory_path}/host_vars"
            case "$base" in
                bastion*) name="bastion" ;;
                *)        name="${base}" ;;
            esac
            ;;
    esac
    cp "$src" "${dest_dir}/${name}"
}

# ----------------------------------------------------------------------
# process_mount
#
# Installs every secret of a mounted GSM group into the inventory.
#
# A missing directory is treated as "nothing to install", not an error:
# callers pass cluster names that aren't always mounted (e.g. a sentinel
# spoke cluster used when a step doesn't need a real one), and skipping
# silently here matches the pre-migration behavior of guarding each
# vault group lookup with an `-d` check.
#
# Parameters:
#   1 - directory: mount path of the GSM group
#   2 - inventory_path: inventory root holding group_vars/ and host_vars/
#   3 - allow_host_vars: "true" to also install non-group vars as host_vars
#   4 - name_filter: optional glob restricting which secrets are installed
# ----------------------------------------------------------------------

process_mount() {
    local directory="$1"
    local inventory_path="$2"
    local allow_host_vars="$3"
    local name_filter="${4:-*}"

    if [ ! -d "$directory" ]; then
        echo "  '$directory' is not mounted, skipping"
        return 0
    fi

    # -L so that files exposed as symlinks by the secrets mount are matched as regular files
    while IFS= read -r filename; do
        install_vars "$filename" "${inventory_path}" "${allow_host_vars}"
    done < <(find -L "$directory" -maxdepth 1 -type f -name "${name_filter}" ! -name '..*' | sort)
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

    local inventory_path="/eco-ci-cd/inventories/ocp-deployment"

    echo "Setting up Ansible inventory for spoke: ${spoke_cluster}, hub: ${hub_cluster}"

    mkdir -p "${inventory_path}/group_vars" "${inventory_path}/host_vars"

    echo "Processing common group_vars"
    process_mount "${COMMON_VARIABLES}" "${inventory_path}" false

    echo "Processing spoke vars (${spoke_cluster})"
    process_mount "${CLUSTER_VARIABLES}/${spoke_cluster}" "${inventory_path}" true

    # Process hypervisor host variables so plays targeting [hypervisor] can resolve the real IP.
    # No setup_direct_ssh here — group_vars/hypervisors provides the SSH key.
    if [[ -f "${HYPERVISOR_VARIABLES}/hypervisor" ]]; then
        echo "Processing hypervisor vars"
        cp "${HYPERVISOR_VARIABLES}/hypervisor" "${inventory_path}/host_vars/hypervisor"
    fi

    if [[ "${hub_cluster}" == "${spoke_cluster}" ]]; then
        # Spoke and hub are the same cluster, so every host of that mount is reached directly.
        local host_vars_file
        for host_vars_file in "${inventory_path}"/host_vars/*; do
            [[ -f "${host_vars_file}" ]] || continue
            [[ "$(basename "${host_vars_file}")" == "hypervisor" ]] && continue
            setup_direct_ssh "${host_vars_file}"
        done
    else
        # Take only the bastion from the hub mount: installing the whole group would
        # drop the hub's master0 on top of the spoke's host_vars of the same name.
        echo "Processing hub bastion vars (${hub_cluster})"
        process_mount "${CLUSTER_VARIABLES}/${hub_cluster}" "${inventory_path}" true 'bastion*'
        if [[ ! -f "${inventory_path}/host_vars/bastion" ]]; then
            echo "Error: no bastion vars found for hub '${hub_cluster}' in ${CLUSTER_VARIABLES}/${hub_cluster}"
            return 1
        fi
        setup_direct_ssh "${inventory_path}/host_vars/bastion"
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
#       locate the bastion secret in /var/clusters/<hub_cluster>
# ----------------------------------------------------------------------

setup_infra_inventory() {
    local hub_cluster="$1"

    local infra_inv="/eco-ci-cd/inventories/infra"

    echo "Setting up infra inventory for hub: ${hub_cluster}"

    mkdir -p "${infra_inv}/group_vars" "${infra_inv}/host_vars"

    echo "Processing common group_vars"
    process_mount "${COMMON_VARIABLES}" "${infra_inv}" false

    if [[ -f "${HYPERVISOR_VARIABLES}/hypervisor" ]]; then
        echo "Processing hypervisor vars"
        cp "${HYPERVISOR_VARIABLES}/hypervisor" "${infra_inv}/host_vars/hypervisor"
    fi

    echo "Processing bastion vars for hub: ${hub_cluster}"
    process_mount "${CLUSTER_VARIABLES}/${hub_cluster}" "${infra_inv}" true 'bastion*'

    # Bastion credentials are required for SSH access to infrastructure playbooks.
    # Fail immediately if missing to catch credential mounting errors early,
    # rather than letting the playbook fail later with a cryptic "host not found" error.
    if [[ ! -d "${infra_inv}/host_vars/bastion" && ! -f "${infra_inv}/host_vars/bastion" ]]; then
        echo "Error: no bastion vars found for hub '${hub_cluster}' in ${CLUSTER_VARIABLES}/${hub_cluster}"
        return 1
    fi

    local host_vars_file
    for host_vars_file in "${infra_inv}"/host_vars/*; do
        [[ -f "${host_vars_file}" ]] || continue
        [[ "$(basename "${host_vars_file}")" == "hypervisor" ]] && continue
        echo "Configuring direct SSH for: $(basename "${host_vars_file}")"
        setup_direct_ssh "${host_vars_file}"
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
# setup_continue_on_fail
#
# When CONTINUE_ON_FAIL=true, sets an ERR trap so that test failures
# exit 0 instead of non-zero. Prow sees success and continues to the
# next step. Intended for development/debugging, not production runs.
#
# Uses set -E (errtrace) so the trap is inherited by functions like main().
# ----------------------------------------------------------------------

setup_continue_on_fail() {
    if [[ "${CONTINUE_ON_FAIL:-false}" == "true" ]]; then
        echo "CONTINUE_ON_FAIL enabled — test failures will not stop the pipeline"
        set -E
        trap 'echo "ERROR: Test failed (exit code $?) but CONTINUE_ON_FAIL=true — continuing"; exit 0' ERR
    fi
}

# ----------------------------------------------------------------------
# setup_debug_on_fail
#
# When DEBUG_ON_FAIL=true AND running in a PR (PULL_NUMBER set),
# sets an EXIT trap that enters a debug wait loop on non-zero exit.
# Unlike continue_on_fail, this preserves the original exit code.
# The step's full context (inventory, vaults, env) remains available
# for interactive debugging via the pod terminal.
#
# Uses DEBUG_TIMEOUT from JSON settings (default: "+10 min") to control
# how long to wait. Sentinel files /tmp/debug.done and /tmp/keep.debugging
# control the loop.
# ----------------------------------------------------------------------

setup_debug_on_fail() {
    if [[ "${DEBUG_ON_FAIL:-false}" != "true" ]]; then
        return 0
    fi
    if [[ -z "${PULL_NUMBER:-}" ]]; then
        echo "DEBUG_ON_FAIL enabled but not a PR run — skipping debug trap"
        return 0
    fi
    echo "DEBUG_ON_FAIL enabled — will enter debug mode on failure (PR ${PULL_NUMBER})"
    trap '__debug_on_fail_exit_handler' EXIT
}

__debug_on_fail_exit_handler() {
    local exit_code=$?
    if [[ ${exit_code} -eq 0 ]]; then
        return 0
    fi

    echo
    echo "################################################################################"
    echo "# PR ${PULL_NUMBER:-} — Step failed (exit code ${exit_code}). Entering debug mode..."
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
    echo "Exiting debug mode with original exit code: ${exit_code}"
    exit ${exit_code}
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
