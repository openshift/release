#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ "${SIZE_VARIANT}" != "compact" ]]; then
    echo "Not a compact (3-node) cluster, nothing to do. " && exit 0
fi

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
if [[ ${nodes_count} -eq ${CONTROL_PLANE_REPLICAS} ]]; then
    matched_count=0
    readarray -t nodes_roles < <(cat ${stdout} | awk '{print $3}')
    for roles in "${nodes_roles[@]}";
    do
        if [[ ${roles} =~ "worker" ]] && [[ ${roles} =~ "master" ]]; then
            matched_count=$(( ${matched_count} + 1 ))
        fi
    done
    if [[ ${matched_count} -eq ${nodes_count} ]]; then
        echo "INFO: Compact (3-node) check passed."
        echo -e "\nnodes:\n$(cat ${stdout})\n"
        exit 0
    fi
fi

echo "ERROR: Compact (3-node) check failed."
echo -e "\n------ STANDARD OUT ------\n$(cat ${stdout})\n------ STANDARD ERROR ------\n$(cat ${stderr})\n"
exit 1
