#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ telcov10n Fix user IDs in a container ************"
[ -e "${HOME}/fix_uid.sh" ] && "${HOME}/fix_uid.sh" || echo "${HOME}/fix_uid.sh was not found" >&2

function generate_shared_functions {

echo "************ telcov10n Generating Shared functions ************"

  functions_path=${SHARED_DIR}/common-telcov10n-bash-functions.sh

  cat <<EO-shared-function >| ${functions_path}
########################################################################
# Common functions used by several steps
########################################################################

EO-shared-function

echo "----------------------------------------------------------------------"
echo " run_script_on_ocp_cluster"
echo "----------------------------------------------------------------------"

  cat <<EO-shared-function >> ${functions_path}

# ----------------------------------------------------------------------
# run_script_on_ocp_cluster
# ----------------------------------------------------------------------

function run_script_on_ocp_cluster {
  local helper_img="${RUN_CMDS_HELPER_IMG}"
  local script_file=\$1
  shift && local ns=\$1
  [ \$# -gt 1 ] && shift && local pod_name="\${1}"

  set -x
  if [[ "\${pod_name:="--rm script-running-on-ocp"}" != "--rm script-running-on-ocp" ]]; then
    oc -n \${ns} get pod \${pod_name} 2> /dev/null || {
      oc -n \${ns} run \${pod_name} --image=\${helper_img} --restart=Never -- sleep infinity || echo ;
      oc -n \${ns} wait --for=condition=Ready pod/\${pod_name} --timeout=10m ;
    }
    for ((attempts = 0 ; attempts < \${max_attempts:=5}; attempts++)); do
      oc -n \${ns} exec -i \${pod_name} -- bash -s -- <<EOF && break
\$(cat \${script_file})
EOF
      oc -n \${ns} get pod
      oc -n \${ns} describe pod \${pod_name}
      sleep 5
    done
    [ \$# -gt 1 ] && oc -n \${ns} delete pod \${pod_name}
    if [ \${attempts} -eq \${max_attempts} ]; then
      set +x
      echo
      echo "[ERROR]. Something fails upon trying to exec the script on the OCP cluster!!!"
      echo
      return 1
    fi
  else
    pn="\${pod_name}-\$(date +%s%N)"
    oc -n \${ns} run -i \${pn} --image=\${helper_img} --restart=Never -- bash -s -- <<EOF
\$(cat \${script_file})
EOF
  fi
  set +x
}
EO-shared-function

echo "----------------------------------------------------------------------"
echo " wait_until_command_is_ok"
echo "----------------------------------------------------------------------"

  cat <<EO-shared-function >> ${functions_path}

# ----------------------------------------------------------------------
# wait_until_command_is_ok
# ----------------------------------------------------------------------

function wait_until_command_is_ok {
  cmd=\$1 ; shift
  [ \$# -gt 0 ] && sleep_for=\${1} && shift && \
  [ \$# -gt 0 ] && max_attempts=\${1} && shift
  [ \$# -gt 0 ] && exit_non_ok_message=\${1} && shift
  for ((attempts = 0 ; attempts <  \${max_attempts:=10} ; attempts++)); do
    echo "Attempting[\${attempts}/\${max_attempts}]..."
    [ "\${show_command:="yes"}" == "yes" ] && set -x
    eval "\${cmd}" && { set +x ; return ; }
    sleep \${sleep_for:='1m'}
    set +x
  done

  echo \${exit_non_ok_message:="[Fail] The exit condition was not met"}
  if [[ "\${TENTATIVE_CREATION:="no"}" == "yes" ]] ; then
    echo "However, since it was set as tentative creation, this failure won't cause the job to stop."
    return 0
  else
    return 1
  fi
}

# ----------------------------------------------------------------------

EO-shared-function

echo "----------------------------------------------------------------------"
echo " setup_aux_host_ssh_access"
echo "----------------------------------------------------------------------"

  cat <<EO-shared-function >> ${functions_path}

# ----------------------------------------------------------------------
# setup_aux_host_ssh_access
# ----------------------------------------------------------------------

function setup_aux_host_ssh_access {

  echo "************ telcov10n Setup AUX_HOST SSH access ************"

  local ssh_key
  if [ \$# -gt 0 ];then
    ssh_key=\${1}
  else
    ssh_key="\${CLUSTER_PROFILE_DIR}/ssh-key"
  fi

  SSHOPTS=(
    -o 'ConnectTimeout=5'
    -o 'StrictHostKeyChecking=no'
    -o 'UserKnownHostsFile=/dev/null'
    -o 'ServerAliveInterval=90'
    -o LogLevel=ERROR
    -i "\${ssh_key}"
  )
}

# ----------------------------------------------------------------------

EO-shared-function

echo "----------------------------------------------------------------------"
echo " try_to_lock_host, check_the_host_was_locked"
echo "----------------------------------------------------------------------"

  cat <<EO-shared-function >> ${functions_path}

# ----------------------------------------------------------------------
# try_to_lock_host
# ----------------------------------------------------------------------

function try_to_lock_host {

  local bastion_host=\${1} ; shift
  local lock_filename=\${1} ; shift
  local ts=\${1} ; shift
  local lock_timeout=\${1}

  set -x
  timeout -s 9 10m ssh "\${SSHOPTS[@]}" "root@\${bastion_host}" bash -s --  \
    "\${lock_filename}" "\${ts}" "\${lock_timeout}" << 'EOF'
set -o nounset
set -o errexit
set -o pipefail

set -x
lock_fname="\${1}"
ts_now="\${2}"
lock_timeout="\${3}"

sudo mkdir -pv \$(dirname \${lock_fname})

if [ -f \${lock_fname} ]; then
  ts_stored=\$(<\${lock_fname})
  time_diff=\$(( ts_now - ts_stored ))
  time_diff=\$(( time_diff < 0 ? 0 : time_diff ))

  # Timeout in nanoseconds (lock_timeut is in seconds)
  lock_timeout_in_ns=\$(( lock_timeout * 1000000000 ))

  # Check if the stored timestamp is at least the timeout older
  if (( time_diff >= lock_timeout_in_ns )); then
    echo "The stored timestamp is at least the timeout older."
    sudo echo "\${ts_now}" >| \${lock_fname}
  else
    echo "The stored timestamp is less than the timeout old."
  fi
else
  sudo echo "\${ts_now}" >| \${lock_fname}
fi
EOF

  set +x
  echo
}

# ----------------------------------------------------------------------
# check_the_host_was_locked
# ----------------------------------------------------------------------

function check_the_host_was_locked {

  local bastion_host=\${1} ; shift
  local lock_filename=\${1} ; shift
  local ts=\${1} ; shift

  set -x
  local ts_stored
  ts_stored=\$(timeout -s 9 10m ssh "\${SSHOPTS[@]}" "root@\${bastion_host}" cat \${lock_filename})
  if (( ts == ts_stored )); then
    echo "locked"
  else
    echo "fail"
  fi
  set +x
}

# ----------------------------------------------------------------------

EO-shared-function

echo "----------------------------------------------------------------------"
echo " extract_ocp_version"
echo "----------------------------------------------------------------------"

  cat <<EO-shared-function >> ${functions_path}

# ----------------------------------------------------------------------
# extract_ocp_version
#
# Extracts the OCP version (e.g., "4.22") from JOB_NAME environment
# variable, which is always set by Prow.
#
# JOB_NAME format examples:
#   periodic-ci-openshift-kni-eco-ci-cd-main-nightly-4.20-telcov10n-...
#   rehearse-72894-periodic-ci-...-nightly-4.22-telcov10n-...
#
# Returns: The major.minor version (e.g., "4.22")
# ----------------------------------------------------------------------

function extract_ocp_version {

  local job_name="\${JOB_NAME:-}"

  if [ -z "\${job_name}" ]; then
    echo "[ERROR] JOB_NAME is not set" >&2
    echo ""
    return 1
  fi

  # Pattern matches: 4.XX or 5.XX in job name
  local version
  version=\$(echo "\${job_name}" | grep -oE '(4|5)\.[0-9]+' | head -1)

  if [ -z "\${version}" ]; then
    echo "[ERROR] Could not extract OCP version from JOB_NAME: \${job_name}" >&2
    echo ""
    return 1
  fi

  echo "\${version}"
}

# ----------------------------------------------------------------------

EO-shared-function

echo "----------------------------------------------------------------------"
echo " compare_ocp_versions, request_graceful_quit, check_graceful_quit_needed"
echo "----------------------------------------------------------------------"

  cat <<EO-shared-function >> ${functions_path}

# ----------------------------------------------------------------------
# compare_ocp_versions
#
# Compares two OCP versions (e.g., 4.19, 4.20, 5.0).
# Returns: "higher" if v1 > v2, "lower" if v1 < v2, "equal" if v1 == v2
#
# Parameters:
#   1 - First version (e.g., "4.22")
#   2 - Second version (e.g., "4.21")
# ----------------------------------------------------------------------

function compare_ocp_versions {
  local v1="\${1}"
  local v2="\${2}"

  # Extract major and minor versions
  local v1_major=\$(echo "\${v1}" | cut -d'.' -f1)
  local v1_minor=\$(echo "\${v1}" | cut -d'.' -f2)
  local v2_major=\$(echo "\${v2}" | cut -d'.' -f1)
  local v2_minor=\$(echo "\${v2}" | cut -d'.' -f2)

  # Compare major versions first
  if (( v1_major > v2_major )); then
    echo "higher"
  elif (( v1_major < v2_major )); then
    echo "lower"
  else
    # Major versions are equal, compare minor
    if (( v1_minor > v2_minor )); then
      echo "higher"
    elif (( v1_minor < v2_minor )); then
      echo "lower"
    else
      echo "equal"
    fi
  fi
}

# ----------------------------------------------------------------------
# create_waiting_request_file
#
# Creates a unique waiting request file on the bastion to signal that
# this job is waiting for the lock. Each job gets its own unique file
# (timestamp + version) to avoid race conditions during cleanup.
#
# File format: <lock_file>.waiting.<timestamp>.<ocp_version>
# Example: spoke-baremetal-50-7c-6f-5c-47-8c.lock.waiting.1703345678.4.22
#
# Parameters:
#   1 - bastion_host
#   2 - spoke_lock_filename (the base lock file path)
#   3 - ocp_version (e.g., "4.22")
#
# Returns via stdout: the created waiting file path (including timestamp)
# ----------------------------------------------------------------------

function create_waiting_request_file {
  local bastion_host="\${1}" ; shift
  local spoke_lock_filename="\${1}" ; shift
  local ocp_version="\${1}"

  # Generate a unique timestamp for this job's waiting file (nanoseconds for uniqueness)
  local timestamp=\$(date -u +%s%N)
  local waiting_file="\${spoke_lock_filename}.waiting.\${timestamp}.\${ocp_version}"

  # Create the file on bastion
  if timeout -s 9 2m ssh "\${SSHOPTS[@]}" "root@\${bastion_host}" \
      "touch \${waiting_file}" 2>/dev/null; then
    echo "\${waiting_file}"
  fi
}

# ----------------------------------------------------------------------
# remove_own_waiting_file
#
# Removes this job's specific waiting file from the bastion. Called when
# the job acquires the lock (no longer waiting) or during cleanup.
# Uses the full path stored in SHARED_DIR to ensure only this job's
# file is removed, not other jobs with the same OCP version.
#
# Parameters:
#   1 - bastion_host
#   2 - waiting_file_path (the full path to this job's waiting file)
# ----------------------------------------------------------------------

function remove_own_waiting_file {
  local bastion_host="\${1}" ; shift
  local waiting_file="\${1}"

  if [ -n "\${waiting_file}" ]; then
    timeout -s 9 2m ssh "\${SSHOPTS[@]}" "root@\${bastion_host}" \
      "rm -f \${waiting_file} 2>/dev/null || true"
  fi
}

# ----------------------------------------------------------------------
# check_for_higher_priority_waiter
#
# Checks all waiting request files on the bastion to find if there's
# a higher priority (newer OCP version) job waiting for the lock.
# This is a lock-free operation - each waiting job has its own unique file.
#
# File format: <lock_file>.waiting.<timestamp>.<ocp_version>
# Example: spoke-baremetal-xx.lock.waiting.1703345678.4.22
#
# SSHs to list waiting files, then processes locally for better error handling.
# Does NOT delete waiting files - each job removes its own file
# when it acquires the lock.
#
# Parameters:
#   1 - bastion_host
#   2 - spoke_lock_filename (the base lock file path)
#   3 - current_ocp_version
#
# Returns via stdout: "quit:<version>" if higher version found, "continue" otherwise
# ----------------------------------------------------------------------

function check_for_higher_priority_waiter {
  local bastion_host="\${1}" ; shift
  local spoke_lock_filename="\${1}" ; shift
  local current_version="\${1}"

  # SSH to list waiting files on bastion
  local waiting_files
  waiting_files=\$(timeout -s 9 2m ssh "\${SSHOPTS[@]}" "root@\${bastion_host}" \
    "ls -1 \${spoke_lock_filename}.waiting.* 2>/dev/null || true")

  if [ -z "\${waiting_files}" ]; then
    echo "[DEBUG] No waiting files found" >&2
    echo "continue"
    return 0
  fi

  echo "[DEBUG] Found waiting files:" >&2
  echo "\${waiting_files}" >&2

  # Find highest version among waiting files (excluding our own version)
  local highest_version=""
  for wf in \${waiting_files}; do
    # Extract version from filename: <lock_file>.waiting.<timestamp>.<version>
    # First remove the lock_file.waiting. prefix, leaving <timestamp>.<version>
    local ts_and_version=\$(echo "\${wf}" | sed "s|\${spoke_lock_filename}.waiting.||")
    # Then extract version by removing the timestamp prefix (first number followed by .)
    local version=\$(echo "\${ts_and_version}" | sed 's/^[0-9]*\.//')

    # Skip if we couldn't parse a version
    if [ -z "\${version}" ] || ! echo "\${version}" | grep -qE '^[0-9]+\.[0-9]+$'; then
      echo "[DEBUG] Skipping invalid waiting file: \${wf}" >&2
      continue
    fi

    echo "[DEBUG] Found waiting version: \${version}" >&2

    if [ -z "\${highest_version}" ]; then
      highest_version="\${version}"
    else
      local cmp=\$(compare_ocp_versions "\${version}" "\${highest_version}")
      if [ "\${cmp}" = "higher" ]; then
        highest_version="\${version}"
      fi
    fi
  done

  # Compare highest waiting version with current version
  if [ -n "\${highest_version}" ]; then
    local cmp=\$(compare_ocp_versions "\${highest_version}" "\${current_version}")
    if [ "\${cmp}" = "higher" ]; then
      echo "[DEBUG] Higher version waiting: \${highest_version} > \${current_version}" >&2
      echo "quit:\${highest_version}"
      return 0
    fi
  fi

  echo "[DEBUG] No higher version waiting" >&2
  echo "continue"
}

# ----------------------------------------------------------------------
# should_quit
#
# Determines if the current job should quit to allow a higher priority
# job to run. Uses a local marker file to avoid repeated checks after
# the decision is made.
#
# Parameters:
#   1 - bastion_host
#   2 - spoke_lock_filename (the base lock file path)
#   3 - current_ocp_version
#   4 - shared_dir (path to SHARED_DIR)
#
# Returns via stdout: "quit" or "continue"
# Side effect: Creates graceful_quit_requested in shared_dir if quitting
# ----------------------------------------------------------------------

function should_quit {
  local bastion_host="\${1}" ; shift
  local spoke_lock_filename="\${1}" ; shift
  local current_version="\${1}" ; shift
  local shared_dir="\${1}"

  # If we already decided to quit, return immediately
  if [ -f "\${shared_dir}/graceful_quit_requested" ]; then
    echo "quit"
    return 0
  fi

  # Check for higher priority waiters on bastion
  local result
  result=\$(check_for_higher_priority_waiter "\${bastion_host}" "\${spoke_lock_filename}" "\${current_version}")

  if [[ "\${result}" == quit:* ]]; then
    local higher_version=\${result#quit:}
    cat <<EOF >| "\${shared_dir}/graceful_quit_requested"
higher_ocp_version=\${higher_version}
current_ocp_version=\${current_version}
EOF
    echo "quit"
  else
    echo "continue"
  fi
}

# ----------------------------------------------------------------------
# setup_ssh_and_lock_info
#
# Initializes SSH access and loads lock-related info from SHARED_DIR.
# Sets up: OCP_VERSION, SPOKE_LOCK_FILENAME
#
# Requires: SHARED_DIR to be set
# ----------------------------------------------------------------------

function setup_ssh_and_lock_info {

  echo "************ telcov10n Setup SSH and lock info ************"

  setup_aux_host_ssh_access

  # Load OCP version from saved file (if available)
  if [ -f "\${SHARED_DIR}/ocp_version.txt" ]; then
    local _ocp_version
    _ocp_version=\$(cat "\${SHARED_DIR}/ocp_version.txt")
    export OCP_VERSION="\${_ocp_version}"
    echo "OCP Version: \${OCP_VERSION}"
  fi

  # Load lock filename if available
  if [ -f "\${SHARED_DIR}/spoke_lock_filename.txt" ]; then
    local _spoke_lock_filename
    _spoke_lock_filename=\$(cat "\${SHARED_DIR}/spoke_lock_filename.txt")
    export SPOKE_LOCK_FILENAME="\${_spoke_lock_filename}"
    echo "Spoke Lock file: \${SPOKE_LOCK_FILENAME}"
  fi
}

# ----------------------------------------------------------------------
# check_for_quit
#
# Checks if a higher priority job is waiting and handles the quit.
#
# Parameters:
#   1 - step_name: Name of the current step (for logging)
#   2 - mode: "graceful" or "force"
#       - graceful: Exit with 0, update SHARED_DIR files so other steps
#                   can continue (e.g., PTP reporting)
#       - force: Exit with 1, remaining steps are meaningless
#                (e.g., cluster installation interrupted)
# ----------------------------------------------------------------------

function check_for_quit {

  local step_name="\${1}"
  local mode="\${2:-graceful}"

  echo "************ telcov10n Checking for quit request at \${step_name} ************"

  if [ -z "\${SPOKE_LOCK_FILENAME:-}" ]; then
    echo "[INFO] No spoke lock filename, skipping quit check."
    return 0
  fi

  if [ -z "\${OCP_VERSION:-}" ]; then
    echo "[WARNING] OCP_VERSION not set, cannot check for quit."
    return 0
  fi

  local quit_decision
  quit_decision=\$(should_quit "\${AUX_HOST}" "\${SPOKE_LOCK_FILENAME}" "\${OCP_VERSION}" "\${SHARED_DIR}")

  if [[ "\${quit_decision}" == "quit" ]]; then
    local higher_version=""
    if [ -f "\${SHARED_DIR}/graceful_quit_requested" ]; then
      # shellcheck disable=SC1090
      source "\${SHARED_DIR}/graceful_quit_requested"
      higher_version="\${higher_ocp_version:-unknown}"
    fi

    if [[ "\${mode}" == "force" ]]; then
      echo
      echo "=============================================================================="
      echo "  FORCED QUIT - HIGHER PRIORITY JOB WAITING"
      echo "=============================================================================="
      echo
      echo "  A higher priority job (newer OCP version) has requested this job to quit."
      echo "  Current job version: \${OCP_VERSION}"
      echo "  Higher version waiting: \${higher_version}"
      echo "  Checkpoint: \${step_name}"
      echo
      echo "  This job will now ABORT to allow the higher priority job to run."
      echo "  Remaining operations will be ABORTED."
      echo
      echo "=============================================================================="
      echo

      # Mark that we're force quitting
      echo -n "force_quit" >| \${SHARED_DIR}/\${step_name}_status.txt

      # Exit with 1 - remaining steps are meaningless
      exit 1
    else
      echo
      echo "=============================================================================="
      echo "  GRACEFUL QUIT REQUESTED"
      echo "=============================================================================="
      echo
      echo "  A higher priority job (newer OCP version) has requested this job to quit."
      echo "  Current job version: \${OCP_VERSION}"
      echo "  Higher version waiting: \${higher_version}"
      echo "  Checkpoint: \${step_name}"
      echo
      echo "  This job will now exit gracefully to allow the higher priority job to run."
      echo "  Remaining operations in this step will be SKIPPED."
      echo
      echo "=============================================================================="
      echo

      # Mark that we're gracefully quitting
      echo -n "graceful_quit" >| \${SHARED_DIR}/\${step_name}_status.txt

      # Exit with 0 so the pipeline continues (e.g., PTP reporting can run)
      exit 0
    fi
  fi

  echo "[INFO] No quit requested, continuing \${step_name}."
}

# ----------------------------------------------------------------------

EO-shared-function

echo "----------------------------------------------------------------------"
echo " extract_cluster_image_set_reference "
echo "----------------------------------------------------------------------"

  cat <<EO-shared-function >> ${functions_path}

# ----------------------------------------------------------------------
# extract_cluster_image_set_reference
#
# Parameter positions:
#
# 1 - the RELEASE_IMAGE_LATEST: OCP image tag
# 2 - the PULL_SECRET that allows to download such image
# ----------------------------------------------------------------------

function extract_cluster_image_set_reference {

  local rel_img
  rel_img=\${1} ; shift

  local pull_secret
  pull_secret=\${1} ; shift

  oc adm release extract -a \${pull_secret} --command=openshift-baremetal-install \${rel_img}
  attempts=0
  while sleep 5s ; do
    ./openshift-baremetal-install version > /dev/null && break
    [ \$(( attempts=\${attempts} + 1 )) -lt 2 ] || exit 1
  done

  echo -n "\$(./openshift-baremetal-install version | head -1 | awk '{print \$2}')"
}

# ----------------------------------------------------------------------

EO-shared-function

  cat ${SHARED_DIR}/"$(basename ${functions_path})"

  echo
  echo "Find generated functions at '\${SHARED_DIR}/$(basename ${functions_path})' path"
  echo
  ls -l ${SHARED_DIR}/"$(basename ${functions_path})"
  echo
}

function main {
  generate_shared_functions
}

main
