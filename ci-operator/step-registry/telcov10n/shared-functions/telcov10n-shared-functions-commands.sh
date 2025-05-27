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
