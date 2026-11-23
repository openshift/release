#!/bin/bash

#
# Delete CloudFormation stack for bootstrap.
#

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

#Save stacks events
trap 'save_stack_events_to_artifacts' EXIT TERM INT

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

STACK_NAME_BOOTSTRAP=$(<"${SHARED_DIR}"/STACK_NAME_BOOTSTRAP)
GATHER_BOOTSTRAP_ARGS="$(<"${SHARED_DIR}"/GATHER_BOOTSTRAP_ARGS)"
SSH_PRIV_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey

source "${SHARED_DIR}/init-fn.sh" || true
# Ensure log is available even when init-fn.sh was not created
# (e.g. teardown after early abort before platform-external-pre-init ran).
if ! type log &>/dev/null; then
  log() { echo "$(date -u --rfc-3339=seconds) - $*"; }
fi

# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
  log "Failed to acquire lease"
  exit 1
fi
AWS_REGION=${LEASED_RESOURCE}

export AWS_DEFAULT_REGION="${AWS_REGION}"  # CLI prefers the former

INSTALL_DIR=/tmp
mkdir -p ${INSTALL_DIR}/auth || true
cp -vf $SHARED_DIR/kubeconfig ${INSTALL_DIR}/auth/

function save_stack_events_to_artifacts() {
  set +o errexit
  aws --region "${AWS_REGION}" cloudformation describe-stack-events --stack-name "${STACK_NAME_BOOTSTRAP}" --output json > "${ARTIFACT_DIR}/stack-events-${STACK_NAME_BOOTSTRAP}.json"
  set -o errexit
}

function gather_bootstrap_and_fail() {
  # In disconnected mode the bootstrap is on a private subnet; route gather
  # through the bastion (same path as collect_bootstrap_handler in init-fn).
  if [[ "${DISCONNECTED_INSTALL:-no}" == "yes" ]] && [[ -s "${SHARED_DIR}/bastion_public_address" ]] && [[ -s "${SHARED_DIR}/bastion_ssh_user" ]]; then
    local bootstrap_ip=""
    if [[ -s "${SHARED_DIR}/BOOTSTRAP_IP" ]]; then
      bootstrap_ip=$(<"${SHARED_DIR}/BOOTSTRAP_IP")
    fi
    if type gather_bootstrap_via_bastion &>/dev/null; then
      gather_bootstrap_via_bastion "${SSH_PRIV_KEY_PATH}" "${bootstrap_ip}"
    else
      log "gather_bootstrap_via_bastion not available; skipping disconnected gather"
    fi
  elif test -n "${GATHER_BOOTSTRAP_ARGS}"; then
    openshift-install --dir=${INSTALL_DIR} gather bootstrap \
        --key "${SSH_PRIV_KEY_PATH}" ${GATHER_BOOTSTRAP_ARGS}
  fi
  return 1
}

install_awscli

log "Waiting for bootstrap to complete"
openshift-install --dir="${INSTALL_DIR}" wait-for bootstrap-complete &
wait "$!" || gather_bootstrap_and_fail

log "Bootstrap complete, destroying bootstrap resources"
aws --region "${AWS_REGION}" cloudformation delete-stack --stack-name "${STACK_NAME_BOOTSTRAP}" &
wait "$!"
