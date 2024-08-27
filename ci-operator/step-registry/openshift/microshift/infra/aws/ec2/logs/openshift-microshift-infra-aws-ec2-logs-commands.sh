#!/bin/bash
set -xeuo pipefail

# shellcheck disable=SC1091
source "${SHARED_DIR}/ci-functions.sh"
ci_script_prologue
trap_subprocesses_on_term

trap 'finalize' EXIT TERM INT

# Look at sos step for the exit codes definitions
function finalize()
{
  if [[ "$?" -ne "0" ]] ; then
    echo "4" >> "${SHARED_DIR}/install-status.txt"
  else
    echo "0" >> "${SHARED_DIR}/install-status.txt"
  fi
}

scp "${INSTANCE_PREFIX}:/tmp/init_output.txt" "${ARTIFACT_DIR}/init_ec2_output.txt"
