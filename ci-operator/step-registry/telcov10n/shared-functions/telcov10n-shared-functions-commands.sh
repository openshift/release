#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ telcov10n Fix user IDs in a container ************"
[ -e "${HOME}/fix_uid.sh" ] && "${HOME}/fix_uid.sh" || echo "${HOME}/fix_uid.sh was not found" >&2

function generate_shared_functions {

echo "************ telcov10n Generating Shared functions ************"

  functions_path=${SHARED_DIR}/spoke-common-functions.sh

  cat <<EO-shared-function >| ${functions_path}
########################################################################
# Common functions used by several steps
########################################################################

EO-shared-function

echo "----------------------------------------------------------------------"
echo " run_script_in_the_hub_cluster"
echo "----------------------------------------------------------------------"

  cat <<EO-shared-function >> ${functions_path}

# ----------------------------------------------------------------------
# run_script_in_the_hub_cluster
# ----------------------------------------------------------------------

function run_script_in_the_hub_cluster {
  local helper_img="${RUN_CMDS_HELPER_IMG}"
  local script_file=\$1
  shift && local ns=\$1
  [ \$# -gt 1 ] && shift && local pod_name="\${1}"

  set -x
  if [[ "\${pod_name:="--rm hub-script"}" != "--rm hub-script" ]]; then
    oc -n \${ns} get pod \${pod_name} 2> /dev/null || {
      oc -n \${ns} run \${pod_name} --image=\${helper_img} --restart=Never -- sleep infinity || echo ;
      oc -n \${ns} wait --for=condition=Ready pod/\${pod_name} --timeout=10m ;
    }
    oc -n \${ns} exec -i \${pod_name} -- bash -s -- <<EOF
\$(cat \${script_file})
EOF
  [ \$# -gt 1 ] && oc -n \${ns} delete pod \${pod_name}
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
    set -x
    eval "\${cmd}" && { set +x ; return ; }
    sleep \${sleep_for:='1m'}
    set +x
  done

  echo \${exit_non_ok_message:="[Fail] The exit condition was not met"}
  if [[ "\${TENTATIVE_CREATION:="no"}" == "yes" ]] ; then
    echo "However, since it was set as tentative creation, this failure won't cause the job to stop."
    exit 0
  else
    exit 1
  fi
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
