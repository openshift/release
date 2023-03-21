#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

source $SHARED_DIR/main.env

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

if [[ "$T5CI_VERSION" == "4.13" ]]; then
    export CNF_BRANCH="master"
elif [[ "$T5CI_VERSION" == "4.14" ]]; then
    export CNF_BRANCH="master"
else
    export CNF_BRANCH="release-${T5CI_VERSION}"
fi

echo "Running for CNF_BRANCH=${CNF_BRANCH}"
if [[ "$CNF_BRANCH" == *"4.11"* ]]; then
    pao_mg_tag="4.11"
fi
if [[ "$CNF_BRANCH" == *"4.12"* ]]; then
    pao_mg_tag="4.12"
fi
if [[ "$CNF_BRANCH" == *"4.13"* ]] || [[ "$CNF_BRANCH" == *"master"* ]]; then
    pao_mg_tag="4.12"
fi

echo "Running PAO must-gather with tag pao_mg_tag=${pao_mg_tag}"
mkdir -p ${ARTIFACT_DIR}/pao-must-gather
echo "OC client version from the container:"
oc version
oc adm must-gather --image=quay.io/openshift-kni/performance-addon-operator-must-gather:${pao_mg_tag}-snapshot --dest-dir=${ARTIFACT_DIR}/pao-must-gather
[ -f "${ARTIFACT_DIR}/pao-must-gather/event-filter.html" ] && cp "${ARTIFACT_DIR}/pao-must-gather/event-filter.html" "${ARTIFACT_DIR}/event-filter.html"
tar -czC "${ARTIFACT_DIR}/pao-must-gather" -f "${ARTIFACT_DIR}/pao-must-gather.tar.gz" .
rm -rf "${ARTIFACT_DIR}"/pao-must-gather
