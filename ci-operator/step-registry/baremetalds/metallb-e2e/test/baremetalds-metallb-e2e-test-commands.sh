#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds metallb e2e test command ************"

# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

METALLB_SRC_DIR="/go/src/github.com/openshift/metallb"
METALLB_OPERATOR_SRC_DIR="/go/src/github.com/openshift/metallb-operator"
METALLB_REPO=${METALLB_REPO:-"https://github.com/openshift/metallb.git"}
METALLB_BRANCH=${METALLB_BRANCH:-"main"}

if [ -d "${METALLB_SRC_DIR}" ]; then
  echo "### Copying metallb directory"
  scp "${SSHOPTS[@]}" -r "${METALLB_SRC_DIR}" "root@${IP}:/root/dev-scripts/"
else
  if [[ -n "${E2E_TESTS_CONFIG:-}" ]]; then
    readarray -t config <<< "${E2E_TESTS_CONFIG}"
    for var in "${config[@]}"; do
      if [[ ! -z "${var}" ]]; then
        if [[ "${var}" == *"METALLB_BRANCH"* ]]; then
          METALLB_BRANCH="$(echo "${var}" | cut -d'=' -f2)"
        fi
      fi
    done
  fi
  echo "### Cloning metallb"
  ssh "${SSHOPTS[@]}" "root@${IP}" "cd /root/dev-scripts/ && rm -rf metallb/ && git clone ${METALLB_REPO} && cd metallb/ && git checkout ${METALLB_BRANCH}"
fi

if [ -d "${METALLB_OPERATOR_SRC_DIR}" ]; then
  echo "### Copying metallb-operator directory"
  scp "${SSHOPTS[@]}" -r "${METALLB_OPERATOR_SRC_DIR}" "root@${IP}:/root/dev-scripts/metallb/openshift-ci/"
fi

# Get additional variables.
vars=""
if [[ -n "${E2E_TESTS_CONFIG:-}" ]]; then
  readarray -t config <<< "${E2E_TESTS_CONFIG}"
  for var in "${config[@]}"; do
    if [[ ! -z "${var}" ]]; then
      vars="${vars} ${var}"
    fi
  done
fi

echo "### deploying metallb through operator"
ssh "${SSHOPTS[@]}" "root@${IP}" "cd /root/dev-scripts/metallb/openshift-ci/ && ${vars} ./deploy_metallb.sh"

echo "### running metallb E2E tests"
ssh "${SSHOPTS[@]}" "root@${IP}" "cd /root/dev-scripts/metallb/openshift-ci/ && ${vars} ./run_e2e.sh"
