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

for nn in "${arr[@]}"; do
    echo "${nn}"
    NS=$(echo ${nn} | cut -d'/' -f1)
    IS=$(echo ${nn} | cut -d'/' -f2)
    

    INPUT_FILE="${TMPDIR}/backup/${NS}_${IS}_api.ci.json"
    OUTPUT_FILE="${TMPDIR}/backup/${NS}_${IS}_app.ci.json"
    PRETTY_OUTPUT_FILE="${TMPDIR}/output/${NS}_${IS}_pretty_app.ci.json"

    oc --context api.ci get is -n "${NS}" "${IS}" -o json > "${INPUT_FILE}"

    ${DIR}/convert.py "${INPUT_FILE}" "${OUTPUT_FILE}" 
    jq . "${OUTPUT_FILE}" > "${PRETTY_OUTPUT_FILE}"

    oc --context api.ci -n ${NS} get secret release-upgrade-graph -o json | jq 'del(.metadata.creationTimestamp) | del(.metadata.resourceVersion) | del(.metadata.selfLink) | del(.metadata.uid)' > "${TMPDIR}/output/${NS}_release-upgrade-graph_app.ci.json"

done

echo "${TMPDIR}/backup"
find "${TMPDIR}/backup" -type f -name "*.json" -exec ls {} \;

echo "${TMPDIR}/output"

cmd="echo"
if [[ "${DRY_RUN:-}" == "false" ]]; then
    cmd="oc"
fi

find "${TMPDIR}/output" -type f -name "*.json" -exec ${cmd} --as system:admin --context app.ci apply -f {} \;