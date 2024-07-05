#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'FRC=$?; debug' EXIT TERM

# Print cv, failed node, co, mcp information for debug purpose
function debug() {
    if (( FRC != 0 )); then
        echo -e "oc get clusterversion/version -oyaml\n$(oc get clusterversion/version -oyaml)"
        echo -e "Describing abnormal nodes...\n"
        oc get node --no-headers | awk '$2 != "Ready" {print $1}' | while read node; do echo -e "\n#####oc describe node ${node}#####\n$(oc describe node ${node})"; done
        echo -e "Describing abnormal operators...\n"
        oc get co --no-headers | awk '$3 != "True" || $4 != "False" || $5 != "False" {print $1}' | while read co; do echo -e "\n#####oc describe co ${co}#####\n$(oc describe co ${co})"; done
        echo -e "Describing abnormal mcp...\n"
        oc get machineconfigpools --no-headers | awk '$3 != "True" || $4 != "False" || $5 != "False" {print $1}' | while read mcp; do echo -e "\n#####oc describe mcp ${mcp}#####\n$(oc describe mcp ${mcp})"; done
    fi
}

function pause() {
    echo "Pausing worker pool..."
    oc patch --type=merge --patch='{"spec":{"paused":true}}' machineconfigpool/worker
    ret=$(oc get machineconfigpools worker -ojson | jq -r '.spec.paused')
    if [[ "${ret}" != "true" ]]; then
        echo >&2 "Worker pool failed to pause, exiting" && return 1
    fi
}

if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

pause
