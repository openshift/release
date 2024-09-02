#!/bin/bash
set -xeuo pipefail

curl https://raw.githubusercontent.com/openshift/release/master/ci-operator/step-registry/openshift/microshift/includes/openshift-microshift-includes-commands.sh -o /tmp/ci-functions.sh
# shellcheck disable=SC1091
source /tmp/ci-functions.sh
ci_script_prologue
trap_subprocesses_on_term

scp -r "${IP_ADDRESS}":/var/log/pcp/pmlogger/* "${ARTIFACT_DIR}/"
