#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
TMPDIR=$(mktemp -d)
mkdir -p "${TMPDIR}/output"
mkdir -p "${TMPDIR}/backup"

declare -a arr=("origin/release" 
                "ocp/release" 
                "ocp-priv/release-priv"
                "ocp-ppc64le/release-ppc64le"
                "ocp-ppc64le-priv/release-ppc64le-priv"
                "ocp-s390x/release-s390x"
                "ocp-s390x-priv/release-s390x-priv"
                )

cmd="echo"
if [[ "${DRY_RUN:-}" == "false" ]]; then
    cmd="oc"
fi

for nn in "${arr[@]}"; do
    echo "${nn}"
    NS=$(echo ${nn} | cut -d'/' -f1)
    IS=$(echo ${nn} | cut -d'/' -f2)

    $cmd --context api.ci delete is -n "${NS}" "${IS}" --wait=false
    $cmd --context api.ci delete secret -n ${NS} release-upgrade-graph --wait=false

done
