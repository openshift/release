set -o errexit
set -o nounset
set -o pipefail

## backup only: hack/delete-release-controllers-imagestreams-api.ci.sh
## delete only: DRY_RUN=false SKIP_BACKUP=true hack/delete-release-controllers-imagestreams-api.ci.sh

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

declare -a arr=("origin/release" 
                "ocp/release" 
                "ocp-priv/release-priv"
                "ocp-ppc64le/release-ppc64le"
                "ocp-ppc64le-priv/release-ppc64le-priv"
                "ocp-s390x/release-s390x"
                "ocp-s390x-priv/release-s390x-priv"
                )

if [[ "${SKIP_BACKUP:-}" != "true" ]]; then
    TMPDIR=$(mktemp -d)
    for nn in "${arr[@]}"; do
        echo "${nn}"
        NS=$(echo ${nn} | cut -d'/' -f1)
        IS=$(echo ${nn} | cut -d'/' -f2)
        OUTPUT_FILE="${TMPDIR}/${NS}_${IS}_app.ci.json"
        oc --context api.ci get is -n "${NS}" "${IS}" -o json > "${OUTPUT_FILE}"
    done
    echo "${TMPDIR}"
fi

cmd="echo"
if [[ "${DRY_RUN:-}" == "false" ]]; then
    cmd="oc"
fi

for nn in "${arr[@]}"; do
    echo "${nn}"
    NS=$(echo ${nn} | cut -d'/' -f1)
    IS=$(echo ${nn} | cut -d'/' -f2)
    $cmd --context api.ci delete is -n "${NS}" "${IS}" --wait=false
done
