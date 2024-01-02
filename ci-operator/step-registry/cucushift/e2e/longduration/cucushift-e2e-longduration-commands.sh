#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CUCUSHIFT_FORCE_SKIP_TAGS="customer security"

function set_cluster_access() {
    if [ -f "${SHARED_DIR}/kubeconfig" ] ; then
        export KUBECONFIG=${SHARED_DIR}/kubeconfig
	echo "KUBECONFIG: ${KUBECONFIG}"
    fi
    cp -Lrvf "${KUBECONFIG}" /tmp/kubeconfig
    if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
        source "${SHARED_DIR}/proxy-conf.sh"
	echo "proxy: ${SHARED_DIR}/proxy-conf.sh"
    fi
}
function preparation_for_test() {
    if ! which kubectl > /dev/null ; then
        mkdir --parents /tmp/bin
        export PATH=$PATH:/tmp/bin
        ln --symbolic "$(which oc)" /tmp/bin/kubectl
    fi
    #shellcheck source=${SHARED_DIR}/runtime_env
    source "${SHARED_DIR}/runtime_env"
}
function echo_e2e_tags() {
    echo "In function: ${FUNCNAME[1]}"
    echo "E2E_RUN_TAGS: '${E2E_RUN_TAGS}'"
    echo "E2E_SKIP_TAGS: '${E2E_SKIP_TAGS}'"
}
function filter_test_by_version() {
    local xversion yversion
    IFS='.' read xversion yversion _ < <(oc version -o yaml | yq '.openshiftVersion')
    if [[ -n $xversion ]] && [[ $xversion -eq 4 ]] && [[ -n $yversion ]] && [[ $yversion =~ [12][0-9] ]] ; then
        export E2E_RUN_TAGS="${E2E_RUN_TAGS} and @${xversion}.${yversion}"
    fi
    echo_e2e_tags
}
function filter_test_by_network() {
    local networktype
    networktype="$(oc get network.config/cluster -o yaml | yq '.spec.networkType')"
    case "${networktype,,}" in
        openshiftsdn)
	    networktag='@network-openshiftsdn'
	    ;;
        ovnkubernetes)
	    networktag='@network-ovnkubernetes'
	    ;;
        *)
	    echo "######Expected network to be SDN/OVN, but got: $networktype"
	    ;;
    esac
    if [[ -n $networktag ]] ; then
        export E2E_RUN_TAGS="${E2E_RUN_TAGS} and ${networktag}"
    fi
    echo_e2e_tags
}
function filter_test_by_sno() {
    local nodeno
    nodeno="$(oc get nodes --no-headers | wc -l)"
    if [[ $nodeno -eq 1 ]] ; then
        export E2E_RUN_TAGS="${E2E_RUN_TAGS} and @singlenode"
    fi
    echo_e2e_tags
}
function filter_test_by_fips() {
    local data
    data="$(oc get configmap cluster-config-v1 -n kube-system -o yaml | yq '.data')"
    if ! (grep --ignore-case --quiet 'fips' <<< "$data") ; then
        export E2E_RUN_TAGS="${E2E_RUN_TAGS} and not @fips"
    fi
    echo_e2e_tags
}
function filter_tests() {
    filter_test_by_version
    filter_test_by_network
    filter_test_by_sno
    filter_test_by_fips
    # the following check should be the last one in filter_tests
    for tag in ${CUCUSHIFT_FORCE_SKIP_TAGS} ; do
        if ! [[ "${E2E_SKIP_TAGS}" =~ $tag ]] ; then
            export E2E_SKIP_TAGS="${E2E_SKIP_TAGS} and not $tag"
        fi
    done
    echo_e2e_tags
}
function test_execution() {
    pushd verification-tests
    # run long duration tests in serial
    export BUSHSLICER_REPORT_DIR="${ARTIFACT_DIR}/longduration"
    export OPENSHIFT_ENV_OCP4_USER_MANAGER_USERS="${USERS}"
    set -x
    cucumber --tags "${E2E_RUN_TAGS} and ${E2E_SKIP_TAGS} and @long-duration" -p junit || true
    set +x
    popd
}
function summarize_test_results() {
    # summarize test results
    echo "Summarizing test results..."
    failures=0 errors=0 skipped=0 tests=0
    grep -r -E -h -o 'testsuite.*tests="[0-9]+"' "${ARTIFACT_DIR}" | tr -d '[A-Za-z=\"_]' > /tmp/zzz-tmp.log
    while read -a row ; do
        # if the last ARG of command `let` evaluates to 0, `let` returns 1
        let failures+=${row[0]} errors+=${row[1]} skipped+=${row[2]} tests+=${row[3]} || true
    done < /tmp/zzz-tmp.log
    TEST_RESULT_FILE="${ARTIFACT_DIR}/test-results.yaml"
    cat > "${TEST_RESULT_FILE}" <<- EOF
cucushift:
  type: cucushift-e2e-longduration
  total: $tests
  failures: $failures
  errors: $errors
  skipped: $skipped
EOF
    if [ $((failures)) != 0 ] ; then
        echo '  failingScenarios:' >> "${TEST_RESULT_FILE}"
        readarray -t failingscenarios < <(grep -h -r -E 'cucumber.*features/.*.feature' "${ARTIFACT_DIR}/.." | cut -d':' -f3- | sed -E 's/^( +)//;s/\x1b\[[0-9;]*m$//' | sort)
        for (( i=0; i<failures; i++ )) ; do
            echo "    - ${failingscenarios[$i]}" >> "${TEST_RESULT_FILE}"
        done
    fi
    cat "${TEST_RESULT_FILE}" | tee -a "${SHARED_DIR}/openshift-e2e-test-qe-report" || true
}


E2E_RUN_TAGS="${E2E_RUN_TAGS:?'Wrong test filter for E2E_RUN_TAGS'}"
E2E_SKIP_TAGS="${E2E_SKIP_TAGS:='not @default-skip-tag-not-used'}"
set_cluster_access
preparation_for_test
filter_tests
test_execution
summarize_test_results
