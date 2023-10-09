#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

source $SHARED_DIR/main.env

function get_sos_report {
    wrknode=$1

    # Execute the script on the node (in a debug pod)
    # Run toolbox to get sosreport, use toolbox from quay.io telco5gci namespace
    # since redhat registry is not accessible from the CI and requires a login
    # Remove the toolbox container before running toolbox if it exists from a previous run
    # Otherwise toolbox will fail to run

    cat <<EOF | oc debug node/${wrknode}
chroot /host bash
cat <<EOZ >/root/.toolboxrc
REGISTRY=quay.io
IMAGE=telco5gci/rhel8/support-tools:latest
EOZ
podman rm -f 'toolbox-root' || true
sleep 5
toolbox sos report --batch --label cijob
exit
EOF
    # Now copy the sosreport from the node to the artifact dir
    oc debug node/${wrknode} -- bash -c 'cat /host/var/tmp/sosreport*cijob*tar.xz' > ${ARTIFACT_DIR}/sosreport-${wrknode}.tar.xz

}

# Check if cluster exists
if [[ ! -e ${SHARED_DIR}/cluster_name ]]; then
    echo "Cluster doesn't exist, job failed, no need to run gather"
    exit 1
fi
##############################################################################
set +e
set -x
cp ${SHARED_DIR}/cnf-tests-run.log ${ARTIFACT_DIR}/cnf-tests-run.log || true
cp ${SHARED_DIR}/cnf-validations-run.log ${ARTIFACT_DIR}/cnf-validations-run.log || true

python3 -m venv ${SHARED_DIR}/myenv
source ${SHARED_DIR}/myenv/bin/activate
git clone https://github.com/openshift-kni/telco5gci ${SHARED_DIR}/telco5gci
pip install -r ${SHARED_DIR}/telco5gci/requirements.txt
# Parse ginkgo output and create JSON file
[[ -f ${SHARED_DIR}/cnf-tests-run.log ]] && python ${SHARED_DIR}/telco5gci/parse_log.py --test-type all --path ${SHARED_DIR}/cnf-tests-run.log --output-file ${ARTIFACT_DIR}/parsed-cnftests.json
[[ -f ${SHARED_DIR}/cnf-validations-run.log ]] && python ${SHARED_DIR}/telco5gci/parse_log.py --test-type validations --path ${SHARED_DIR}/cnf-validations-run.log --output-file ${ARTIFACT_DIR}/parsed-validations.json
[[ -f ${SHARED_DIR}/cnf-tests-run.log ]] && python ${SHARED_DIR}/telco5gci/parse_log.py --test-type tests --path ${SHARED_DIR}/cnf-tests-run.log --output-file ${ARTIFACT_DIR}/parsed-tests.json
# Create HTML reports for humans/aliens
[[ -f ${ARTIFACT_DIR}/parsed-cnftests.json ]] && python ${SHARED_DIR}/telco5gci/j2html.py ${ARTIFACT_DIR}/parsed-cnftests.json -f json -o ${ARTIFACT_DIR}/parsed-cnftests.html
[[ -f ${ARTIFACT_DIR}/parsed-validations.json ]] && python ${SHARED_DIR}/telco5gci/j2html.py ${ARTIFACT_DIR}/parsed-validations.json -f json -o ${ARTIFACT_DIR}/parsed_validations.html
[[ -f ${ARTIFACT_DIR}/parsed-tests.json ]] && python ${SHARED_DIR}/telco5gci/j2html.py ${ARTIFACT_DIR}/parsed-tests.json -f json -o ${ARTIFACT_DIR}/parsed-tests.html

rm -rf ${SHARED_DIR}/myenv
set +x
set -e
##############################################################################

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
echo "OC client version from the container:"
oc version

echo "Gather sosreport from nodes"
# get_sos_report from all nodes with "cnf" in the name
for node in $(oc get node -oname | grep cnf); do
  echo "Collecting sosreport for ${node##*/}"
  get_sos_report ${node##*/} || true
done

echo "Running gather-pao for T5CI_VERSION=${T5CI_VERSION}"

if [[ "$T5CI_VERSION" == "4.13" ]]; then
    export CNF_BRANCH="master"
elif [[ "$T5CI_VERSION" == "4.14" ]]; then
    export CNF_BRANCH="master"
elif [[ "$T5CI_VERSION" == "4.15" ]]; then
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

oc adm must-gather --image=quay.io/openshift-kni/performance-addon-operator-must-gather:${pao_mg_tag}-snapshot --dest-dir=${ARTIFACT_DIR}/pao-must-gather
[ -f "${ARTIFACT_DIR}/pao-must-gather/event-filter.html" ] && cp "${ARTIFACT_DIR}/pao-must-gather/event-filter.html" "${ARTIFACT_DIR}/event-filter.html"
tar -czC "${ARTIFACT_DIR}/pao-must-gather" -f "${ARTIFACT_DIR}/pao-must-gather.tar.gz" .
rm -rf "${ARTIFACT_DIR}"/pao-must-gather
