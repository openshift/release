#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds metallb e2e test command ************"

# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

# Extract and format the oc version to branch
extract_version() {
  output="$1"
  version_line=$(echo "$output" | grep "$2")
  version=$(echo "$version_line" | awk '{print $3}')
  major=$(echo "$version" | cut -d '.' -f 1)
  minor=$(echo "$version" | cut -d '.' -f 2)
  oc_branch="release-$major.$minor"
  echo "$oc_branch"
}
OC_VERSION=$(ssh "${SSHOPTS[@]}" "root@${IP}" "oc version")
OC_BRANCH=$(extract_version "${OC_VERSION}" "Server Version:")
METALLB_SRC_DIR="/go/src/github.com/openshift/metallb"
FRRK8S_SRC_DIR="/go/src/github.com/openshift/frr"
METALLB_OPERATOR_SRC_DIR="/go/src/github.com/openshift/metallb-operator"
METALLB_REPO=${METALLB_REPO:-"https://github.com/openshift/metallb.git"}
FRRK8S_REPO=${FRRK8S_REPO:-"https://github.com/openshift/frr.git"}

METALLB_BRANCH="${OC_BRANCH}"
FRRK8S_BRANCH="${OC_BRANCH}"
DONT_DEPLOY_OPERATOR=${DONT_DEPLOY_OPERATOR:-}

if [ -d "${METALLB_SRC_DIR}" ]; then
  echo "### Copying metallb directory"
  scp "${SSHOPTS[@]}" -r "${METALLB_SRC_DIR}" "root@${IP}:/root/dev-scripts/"
else
  echo "### Cloning metallb"
  ssh "${SSHOPTS[@]}" "root@${IP}" "cd /root/dev-scripts/ && rm -rf metallb/ && git clone ${METALLB_REPO} && cd metallb/ && git checkout ${METALLB_BRANCH}"
fi

if [ -d "${FRRK8S_SRC_DIR}" ]; then
  echo "### Copying frr directory"
  scp "${SSHOPTS[@]}" -r "${FRRK8S_SRC_DIR}" "root@${IP}:/root/dev-scripts/"
else
  echo "### Cloning frr"
  ssh "${SSHOPTS[@]}" "root@${IP}" "cd /root/dev-scripts/ && rm -rf frr/ && git clone ${FRRK8S_REPO} && cd frr/ && git checkout ${FRRK8S_BRANCH}"
fi

if [ -d "${METALLB_OPERATOR_SRC_DIR}" ]; then
  echo "### Copying metallb-operator directory"
  scp "${SSHOPTS[@]}" -r "${METALLB_OPERATOR_SRC_DIR}" "root@${IP}:/root/dev-scripts/metallb/openshift-ci/"
fi

# Get additional variables.
vars="METALLB_OPERATOR_BRANCH=${OC_BRANCH}"
if [[ -n "${E2E_TESTS_CONFIG:-}" ]]; then
  readarray -t config <<< "${E2E_TESTS_CONFIG}"
  for var in "${config[@]}"; do
    if [[ ! -z "${var}" ]]; then
      vars="${vars} ${var}"
    fi
  done
fi

if [[ -z $DONT_DEPLOY_OPERATOR ]]; then
  echo "### deploying metallb through operator"
  ssh "${SSHOPTS[@]}" "root@${IP}" "cd /root/dev-scripts/metallb/openshift-ci/ && ${vars} ./deploy_metallb.sh"
fi
echo "### running metallb E2E tests"
ssh "${SSHOPTS[@]}" "root@${IP}" "cd /root/dev-scripts/metallb/openshift-ci/ && ${vars} ./run_e2e.sh"

scp "${SSHOPTS[@]}" -r "root@${IP}:/logs/artifacts" "${ARTIFACT_DIR}"
