#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

echo "************ assisted tools build+publish multi arch ************"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../../common/lib/host-contract/assisted-common-lib-host-contract-commands.sh"

host_contract::load

HOST_TARGET="${HOST_SSH_USER}@${HOST_SSH_HOST}"
SSH_ARGS=("${HOST_SSH_OPTIONS[@]}")

echo "### Building multi arch images"
timeout --kill-after 10m 120m ssh "${SSH_ARGS[@]}" "${HOST_TARGET}" bash -x - << EOF
    cd /home/assisted

    EXTRA_PARAMS=""
    if [ "${DRY_RUN}" = "false" ]
    then
      EXTRA_PARAMS="--push"
    fi

    # workaround for error 
    # 'fatal: detected dubious ownership in repository at '/go/src/github.com/openshift/assisted-installer'
    # https://nvd.nist.gov/vuln/detail/cve-2022-24765
    git config --global --add safe.directory '*'

    echo "${DOCKERFILE_IMAGE_PAIRS}" | tr -d '[:space:]' | awk -F , 'BEGIN{RS="|"}{printf("-f %s -t %s\n", \$1, \$2)}' | \
    while read -r params ; do
      docker buildx build --platform linux/amd64,linux/arm64,linux/ppc64le,linux/s390x . \${EXTRA_PARAMS} \$params
    done
EOF
