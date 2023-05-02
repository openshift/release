#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds metallb install command ************"

# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

METALLB_SRC_DIR="/go/src/github.com/openshift/metallb"
METALLB_REPO=${METALLB_REPO:-"https://github.com/openshift/metallb.git"}
METALLB_BRANCH=${METALLB_BRANCH:-"main"}

if [ -d "${METALLB_SRC_DIR}" ]; then
  echo "### Copying metallb directory"
  scp "${SSHOPTS[@]}" -r "${METALLB_SRC_DIR}" "root@${IP}:/root/dev-scripts/"
else
  echo "### Cloning metallb"
  ssh "${SSHOPTS[@]}" "root@${IP}" "cd /root/dev-scripts/ && rm -rf metallb/ && git clone ${METALLB_REPO} && cd metallb/ && git checkout ${METALLB_BRANCH}"
fi

echo "### deploying metallb through operator"
ssh "${SSHOPTS[@]}" "root@${IP}" "cd /root/dev-scripts/metallb/openshift-ci/ && ./deploy_metallb.sh"