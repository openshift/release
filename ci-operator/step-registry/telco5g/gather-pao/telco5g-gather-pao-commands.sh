#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ telco5g gather-pao commands ************"

pao_mg_tag="4.10" # pao must-gather does not have 'latest' tag - setting 4.10 as a workaround for now.
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
