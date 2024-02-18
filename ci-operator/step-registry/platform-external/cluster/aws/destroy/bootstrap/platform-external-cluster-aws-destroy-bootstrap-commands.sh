#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

#Save stacks events
trap 'save_stack_events_to_artifacts' EXIT TERM INT

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

STACK_NAME_BOOTSTRAP=$(<"${SHARED_DIR}"/STACK_NAME_BOOTSTRAP)

SSH_PRIV_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey
GATHER_BOOTSTRAP_ARGS=

source "${SHARED_DIR}/init-fn.sh" || true

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

function save_stack_events_to_artifacts()
{
  set +o errexit
  aws --region ${AWS_REGION} cloudformation describe-stack-events --stack-name "${STACK_NAME_BOOTSTRAP}" --output json > "${ARTIFACT_DIR}/stack-events-${STACK_NAME_BOOTSTRAP}.json"
  set -o errexit
}

function gather_bootstrap_and_fail() {
  if test -n "${GATHER_BOOTSTRAP_ARGS}"; then
    openshift-install --dir=${INSTALL_DIR} gather bootstrap \
        --key "${SSH_PRIV_KEY_PATH}" ${GATHER_BOOTSTRAP_ARGS}
  fi
  return 1
}

install_awscli

echo "Waiting for bootstrap to complete"
openshift-install --dir="${INSTALL_DIR}" wait-for bootstrap-complete &
wait "$!" || gather_bootstrap_and_fail

echo "Bootstrap complete, destroying bootstrap resources"
aws cloudformation delete-stack --stack-name "${STACK_NAME_BOOTSTRAP}" &
wait "$!"

aws cloudformation wait stack-delete-complete --stack-name "${STACK_NAME_BOOTSTRAP}" &
wait "$!"