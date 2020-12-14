#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

declare -a namespaces=("ci-release-ppc64le-priv"
                       "ci-release-ppc64le"
                       "ci-release-priv"
                       "ci-release-s390x-priv"
                       "ci-release-s390x"
                       "ci-release"
                       )

declare -a resources=("statefulset.apps/files-cache"
                      "statefulset.apps/git-cache"
                      "service/files-cache"
                      "route.route.openshift.io/files-cache"
                      )

cmd="echo"
if [[ "${DRY_RUN:-}" == "false" ]]; then
    cmd="oc"
fi

for namespace in "${namespaces[@]}"; do
    echo "${namespace}"
    for resource in "${resources[@]}"; do
        echo "  ${resource}"
        $cmd --context api.ci -n "${namespace}" delete "${resource}" --wait=false
    done
    echo
done

exit 0
