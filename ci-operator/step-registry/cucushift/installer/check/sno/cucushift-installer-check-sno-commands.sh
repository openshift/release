#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

stderr=$(mktemp)
stdout=$(mktemp)
oc get nodes --no-headers 1>${stdout} 2>${stderr} || true

nodes_count=$(cat "${stdout}" | wc -l || true)
roles=$(cat "${stdout}" | awk '{print $3}' || true)

if [[ ${nodes_count} -eq 1 ]] && [[ ${roles} =~ "worker" ]] && [[ ${roles} =~ "master" ]]; then
    echo "INFO: SNO check passed."
    echo -e "\nnodes:\n$(cat ${stdout})\n"
    exit 0
else
    echo "ERROR: SNO check failed."
    echo -e "\n------ STANDARD OUT ------\n$(cat ${stdout})\n------ STANDARD ERROR ------\n$(cat ${stderr})\n"
    exit 1
fi
