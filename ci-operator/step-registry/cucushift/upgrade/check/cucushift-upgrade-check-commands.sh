#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

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
    upuser1=$(echo "${USERS}" | cut -d ',' -f 30)
    upuser2=$(echo "${USERS}" | cut -d ',' -f 29)
    export BUSHSLICER_CONFIG="
global:
  browser: chrome
environments:
  ocp4:
    static_users_map:
      upuser1: '${upuser1}'
      upuser2: '${upuser2}'
"
}
function echo_upgrade_tags() {
    echo "In function: ${FUNCNAME[1]}"
    echo "UPGRADE_CHECK_RUN_TAGS: '${UPGRADE_CHECK_RUN_TAGS}'"
}
function filter_test_by_version() {
    local xversion yversion
    IFS='.' read xversion yversion _ < <(oc get clusterversion version -o yaml | yq '.status.history[].version' | head -2 | tail -1)
    if [[ -n $xversion ]] && [[ $xversion -eq 4 ]] && [[ -n $yversion ]] && [[ $yversion =~ [12][0-9] ]] ; then
        export UPGRADE_CHECK_RUN_TAGS="@${xversion}.${yversion} and ${UPGRADE_CHECK_RUN_TAGS}"
    fi
    echo_upgrade_tags
}
function filter_test_by_arch() {
    local node_archs arch_tags
    mapfile -t node_archs < <(oc get nodes -o yaml | yq '.items[].status.nodeInfo.architecture' | sort -u | sed 's/^/@/g')
    arch_tags="${node_archs[*]/%/ and}"
    case "${#node_archs[@]}" in
        0)
            echo "=========================="
            echo "Error: got unexpected arch"
            oc get nodes -o yaml
            echo "=========================="
            ;;
        1)
            export UPGRADE_CHECK_RUN_TAGS="${arch_tags[*]} ${UPGRADE_CHECK_RUN_TAGS}"
            ;;
        *)
            export UPGRADE_CHECK_RUN_TAGS="@heterogeneous and ${arch_tags[*]} ${UPGRADE_CHECK_RUN_TAGS}"
            ;;
    esac
    echo_upgrade_tags
}
function filter_test_by_platform() {
    local platform ipixupi
    ipixupi='upi'
    if (oc get configmap openshift-install -n openshift-config &>/dev/null) ; then
        ipixupi='ipi'
    fi
    platform="$(oc get infrastructure cluster -o yaml | yq '.status.platform' | tr 'A-Z' 'a-z')"
    extrainfoCmd="oc get infrastructure cluster -o yaml | yq '.status'"
    if [[ -n "$platform" ]] ; then
        case "$platform" in
            none)
                export UPGRADE_CHECK_RUN_TAGS="@baremetal-upi and ${UPGRADE_CHECK_RUN_TAGS}"
                eval "$extrainfoCmd"
                ;;
            external)
                echo "Expected, got platform as '$platform'"
                eval "$extrainfoCmd"
                ;;
            alibabacloud)
                export UPGRADE_CHECK_RUN_TAGS="@alicloud-${ipixupi} and ${UPGRADE_CHECK_RUN_TAGS}"
                ;;
            aws|azure|baremetal|gcp|ibmcloud|nutanix|openstack|vsphere)
                export UPGRADE_CHECK_RUN_TAGS="@${platform}-${ipixupi} and ${UPGRADE_CHECK_RUN_TAGS}"
                ;;
            *)
                echo "Unexpected, got platform as '$platform'"
                eval "$extrainfoCmd"
                ;;
        esac
    fi
    echo_upgrade_tags
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
        export UPGRADE_CHECK_RUN_TAGS="${networktag} and ${UPGRADE_CHECK_RUN_TAGS}"
    fi
    echo_upgrade_tags
}
function filter_test_by_sno() {
    local nodeno
    nodeno="$(oc get nodes --no-headers | wc -l)"
    if [[ $nodeno -eq 1 ]] ; then
        export UPGRADE_CHECK_RUN_TAGS="@singlenode and ${UPGRADE_CHECK_RUN_TAGS}"
    fi
    echo_upgrade_tags
}
function filter_test_by_proxy() {
    local proxy
    proxy="$(oc get proxies.config.openshift.io cluster -o yaml | yq '.spec|(.httpProxy,.httpsProxy)' | uniq)"
    if [[ -n "$proxy" ]] && [[ "$proxy" != 'null' ]] ; then
        export UPGRADE_CHECK_RUN_TAGS="@proxy and ${UPGRADE_CHECK_RUN_TAGS}"
    fi
    echo_upgrade_tags
}
function filter_test_by_fips() {
    local data
    data="$(oc get configmap cluster-config-v1 -n kube-system -o yaml | yq '.data')"
    if ! (grep --ignore-case --quiet 'fips' <<< "$data") ; then
        export UPGRADE_CHECK_RUN_TAGS="not @fips and ${UPGRADE_CHECK_RUN_TAGS}"
    fi
    echo_upgrade_tags
}
function filter_test_by_capability() {
    local enabledcaps xversion yversion
    enabledcaps="$(oc get clusterversion version -o yaml | yq '.status.capabilities.enabledCapabilities[]')"
    IFS='.' read xversion yversion _ < <(oc version -o yaml | yq '.openshiftVersion')
    local v411 v412 v413 v414 v415 v416
    v411="baremetal marketplace openshift-samples"
    v412="${v411} Console Insights Storage CSISnapshot"
    v413="${v412} NodeTuning"
    v414="${v413} MachineAPI Build DeploymentConfig ImageRegistry"
    v415="${v414} OperatorLifecycleManager CloudCredential"
    v416="${v415}"
    # [console]=console
    # the first `console` is the capability name
    # the second `console` is the tag name in verification-tests
    declare -A tagmaps
    tagmaps=([baremetal]=xxx
             [Build]=xxx
             [CloudCredential]=xxx
             [Console]=console
             [CSISnapshot]=storage
             [DeploymentConfig]=xxx
             [ImageRegistry]=xxx
             [Insights]=xxx
             [MachineAPI]=xxx
             [marketplace]=xxx
             [NodeTuning]=xxx
             [openshift-samples]=xxx
             [OperatorLifecycleManager]=xxx
             [Storage]=storage
    )
    local versioncaps
    versioncaps="$v416"
    case "$xversion.$yversion" in
        4.16)
            versioncaps="$v416"
            ;;
        4.15)
            versioncaps="$v415"
            ;;
        4.14)
            versioncaps="$v414"
            ;;
        4.13)
            versioncaps="$v413"
            ;;
        4.12)
            versioncaps="$v412"
            ;;
        4.11)
            versioncaps="$v411"
            ;;
        *)
            versioncaps=""
            echo "Got unexpected version: $xversion.$yversion"
            ;;
    esac
    for cap in ${versioncaps} ; do
        if ! (grep --ignore-case --quiet "$cap" <<< "$enabledcaps") ; then
            if [[ "${tagmaps[$cap]}" != 'xxx' ]] ; then
                export UPGRADE_CHECK_RUN_TAGS="not @${tagmaps[$cap]} and ${UPGRADE_CHECK_RUN_TAGS}"
            else
                echo "TO_BE_DONE: find tag map for '$cap'"
            fi
        fi
    done
    echo_upgrade_tags
}
function filter_tests() {
    filter_test_by_capability
    filter_test_by_fips
    filter_test_by_proxy
    filter_test_by_sno
    filter_test_by_network
    filter_test_by_platform
    filter_test_by_arch
    filter_test_by_version

    echo_upgrade_tags
}
function test_execution() {
    pushd verification-tests
    export OPENSHIFT_ENV_OCP4_USER_MANAGER=UpgradeUserManager
    export OPENSHIFT_ENV_OCP4_USER_MANAGER_USERS=${USERS}
    export BUSHSLICER_REPORT_DIR="${ARTIFACT_DIR}"
    set -x
    cucumber --tags "${UPGRADE_CHECK_RUN_TAGS} and @upgrade-check" -p junit || true
    CLOUD_SPECIFIC_TAGS="${CUCUSHIFT_FORCE_SKIP_TAGS/and not @destructive/}"
    cucumber --tags "${UPGRADE_CHECK_RUN_TAGS} and @upgrade-check and ${CLOUD_SPECIFIC_TAGS} and @cloud and @destructive" -p junit || true
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
  type: cucushift-upgrade-check
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
    cat "${TEST_RESULT_FILE}" | tee -a "${SHARED_DIR}/openshift-upgrade-qe-test-report" || true
}


CUCUSHIFT_FORCE_SKIP_TAGS="not @customer
        and not @destructive
        and not @flaky
        and not @inactive
        and not @prod-only
        and not @qeci
        and not @security
        and not @stage-only
"
if [[ -z "$UPGRADE_CHECK_RUN_TAGS" ]] ; then
    export UPGRADE_CHECK_RUN_TAGS="$CUCUSHIFT_FORCE_SKIP_TAGS"
else
    export UPGRADE_CHECK_RUN_TAGS="$UPGRADE_CHECK_RUN_TAGS and $CUCUSHIFT_FORCE_SKIP_TAGS"
fi
set_cluster_access
preparation_for_test
filter_tests
test_execution
summarize_test_results
