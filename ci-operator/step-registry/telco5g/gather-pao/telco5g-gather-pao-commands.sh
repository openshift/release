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

if [[ -n "${E2E_TESTS_CONFIG:-}" ]]; then
    readarray -t config <<< "${E2E_TESTS_CONFIG}"
    for var in "${config[@]}"; do
        if [[ ! -z "${var}" ]]; then
            if [[ "${var}" == *"CNF_BRANCH"* ]]; then
                CNF_BRANCH="$(echo "${var}" | cut -d'=' -f2)"
            elif [[ "${var}" == *"FEATURES"* ]]; then
                FEATURES="$(echo "${var}" | cut -d'=' -f2 | tr -d '"')"
            fi
        fi
    done
fi

###############################################################################
# Copy all artifacts from the previous step
ls -lash ${SHARED_DIR}
ls -lash ${SHARED_DIR}/cnf-tests-artifacts/

cp -r ${SHARED_DIR}/cnf-tests-artifacts/* ${ARTIFACT_DIR}/

# Create reports from CNF tests if exist
for feature in ${FEATURES}; do
    xml_f="${ARTIFACT_DIR}/${feature}/cnftests-junit.xml"
    if [[ -f $xml_f ]]; then
        cp $xml_f ${ARTIFACT_DIR}/cnftests-junit_${feature}.xml
    fi
    xml_v="${ARTIFACT_DIR}/${feature}/validation_junit.xml"
    if [[ -f $xml_v ]]; then
        cp $xml_v ${ARTIFACT_DIR}/validation_junit_${feature}.xml
    fi
    xml_s="${ARTIFACT_DIR}/${feature}/setup_junit.xml"
    if [[ -f $xml_s ]]; then
        cp $xml_s ${ARTIFACT_DIR}/setup_junit_${feature}.xml
    fi
done
python3 -m venv ${SHARED_DIR}/myenv
source ${SHARED_DIR}/myenv/bin/activate
git clone https://github.com/sshnaidm/html4junit.git ${SHARED_DIR}/html4junit
pip install -r ${SHARED_DIR}/html4junit/requirements.txt
# Create HTML reports for humans/aliens
python ${SHARED_DIR}/html4junit/j2html.py ${ARTIFACT_DIR}/cnftests-junit*xml -o ${ARTIFACT_DIR}/test_results.html || true
python ${SHARED_DIR}/html4junit/j2html.py ${ARTIFACT_DIR}/validation_junit*xml -o ${ARTIFACT_DIR}/validation_results.html || true
python ${SHARED_DIR}/html4junit/j2html.py ${ARTIFACT_DIR}/setup_junit_*xml -o ${ARTIFACT_DIR}/setup_results.html || true
# Create JSON reports for robots
python ${SHARED_DIR}/html4junit/junit2json.py ${ARTIFACT_DIR}/cnftests-junit*xml -o ${ARTIFACT_DIR}/test_results.json || true
python ${SHARED_DIR}/html4junit/junit2json.py ${ARTIFACT_DIR}/validation_junit*xml -o ${ARTIFACT_DIR}/validation_results.json || true
python ${SHARED_DIR}/html4junit/junit2json.py ${ARTIFACT_DIR}/setup_junit_*xml -o ${ARTIFACT_DIR}/setup_results.json || true

rm -rf ${SHARED_DIR}/myenv ${ARTIFACT_DIR}/setup_junit_*xml ${ARTIFACT_DIR}/validation_junit*xml ${ARTIFACT_DIR}/cnftests-junit_*xml
###############################################################################


echo "Running for CNF_BRANCH=${CNF_BRANCH}"
if [[ "$CNF_BRANCH" == *"4.11"* ]]; then
    pao_mg_tag="4.11"
fi
if [[ "$CNF_BRANCH" == *"4.12"* ]] || [[ "$CNF_BRANCH" == *"master"* ]]; then
    pao_mg_tag="4.12"
fi
if [[ "$CNF_BRANCH" == *"4.13"* ]]; then
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
