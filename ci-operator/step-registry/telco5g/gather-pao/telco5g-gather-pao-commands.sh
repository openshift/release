#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Check if cluster exists
if [[ ! -e ${SHARED_DIR}/cluster_name ]]; then
    echo "Cluster doesn't exist, job failed, no need to run gather"
    exit 1
fi

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
	# shellcheck disable=SC1090
	source "${SHARED_DIR}/proxy-conf.sh"
fi

echo "************ telco5g gather-pao commands ************"

pao_mg_tag="4.10" # pao must-gather does not have 'latest' tag - setting 4.10 as a workaround for now.
PULL_BASE_REF=${PULL_BASE_REF:-"master"}
if [ ${PULL_BASE_REF} != "master" ]
then
        pao_mg_tag=${PULL_BASE_REF##release-}
fi

echo "Running pao-must-gather ${pao_mg_tag}-snapshot..."
mkdir -p ${ARTIFACT_DIR}/pao-must-gather
oc adm must-gather --image=quay.io/openshift-kni/performance-addon-operator-must-gather:${pao_mg_tag}-snapshot --dest-dir=${ARTIFACT_DIR}/pao-must-gather
[ -f "${ARTIFACT_DIR}/pao-must-gather/event-filter.html" ] && cp "${ARTIFACT_DIR}/pao-must-gather/event-filter.html" "${ARTIFACT_DIR}/event-filter.html"
tar -czC "${ARTIFACT_DIR}/pao-must-gather" -f "${ARTIFACT_DIR}/pao-must-gather.tar.gz" .
rm -rf "${ARTIFACT_DIR}"/pao-must-gather
