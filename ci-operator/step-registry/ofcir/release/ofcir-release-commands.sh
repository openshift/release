#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ ofcir packet teardown command ************"

CIRFILE=$SHARED_DIR/cir
if [ -e "$CIRFILE" ] ; then
    NAME=$(jq -r .name < "$CIRFILE")
    echo "Releasing CIR $NAME"
    OFCIR_REQUESTER="${JOB_NAME}/${BUILD_ID}"
    OFCIR_ROLE="${OFCIR_ROLE:-}"
    if [[ -z "${OFCIR_ROLE}" && -f "${SHARED_DIR}/ofcir-role" ]]; then
        OFCIR_ROLE="$(<"${SHARED_DIR}/ofcir-role")"
    fi
    if [[ -n "${OFCIR_ROLE}" ]]; then
        if [[ ! "${OFCIR_ROLE}" =~ ^[a-z0-9-]+$ ]]; then
            echo "Invalid OFCIR role" >&2
            exit 1
        fi
        OFCIR_REQUESTER="${OFCIR_REQUESTER}-${OFCIR_ROLE}"
    fi
    OFCIRURL="https://ofcir.apps-int.master.ci.devcluster.openshift.com/v1/ofcir"
    OFCIRTOKEN="$(cat "${CLUSTER_PROFILE_DIR}/ofcir-auth-token")"
    rv="99"
    if [[ -s "${SHARED_DIR}/install-status.txt" ]]; then
        rv="$(awk 'NR == 1 {print $1}' "${SHARED_DIR}/install-status.txt")"
    fi
    curl --retry-all-errors --retry-delay 60 --retry 1 -kfX DELETE -H "X-OFCIRTOKEN: $OFCIRTOKEN" "$OFCIRURL/${NAME}?name=$OFCIR_REQUESTER&rv=$rv"
    exit 0
fi
