#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function run_command() {
    local CMD="$1"
    echo "Running command: ${CMD}"
    eval "${CMD}"
}

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
    if ! which kubectl &> /dev/null ; then
        mkdir --parents /tmp/bin
        export PATH=$PATH:/tmp/bin
        ln --symbolic "$(which oc)" /tmp/bin/kubectl
    fi
    #shellcheck source=${SHARED_DIR}/runtime_env
    source "${SHARED_DIR}/runtime_env"
    IFS=',' read upuser1 upuser2 _ < <(echo $USERS | cut -d',' -f8-10)
    apiport="$(yq '.environments.ocp4.api_port' <<< $BUSHSLICER_CONFIG)"
    version="$(yq '.environments.ocp4.version' <<< $BUSHSLICER_CONFIG)"
    browser="$(yq '.global.browser' <<< $BUSHSLICER_CONFIG)"
    export BUSHSLICER_CONFIG="
global:
  browser: '${browser}'
environments:
  ocp4:
    api_port: '${apiport}'
    version: '${version}'
    static_users_map:
      upuser1: '${upuser1}'
      upuser2: '${upuser2}'
"
}
function echo_upgrade_tags() {
    echo "In function: ${FUNCNAME[1]}"
    echo "UPGRADE_PRE_RUN_TAGS: '${UPGRADE_PRE_RUN_TAGS}'"
}
function filter_test_by_version() {
    local xversion yversion
    IFS='.' read xversion yversion _ < <(oc get clusterversion version -o yaml | yq '.status.history[0].version')
    if [[ -n $xversion ]] && [[ $xversion -eq 4 ]] && [[ -n $yversion ]] && [[ $yversion =~ [12][0-9] ]] ; then
        export UPGRADE_PRE_RUN_TAGS="@${xversion}.${yversion} and ${UPGRADE_PRE_RUN_TAGS}"
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
            export UPGRADE_PRE_RUN_TAGS="${arch_tags[*]} ${UPGRADE_PRE_RUN_TAGS}"
            ;;
        *)
            export UPGRADE_PRE_RUN_TAGS="@heterogeneous and ${arch_tags[*]} ${UPGRADE_PRE_RUN_TAGS}"
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
            external|kubevirt|none|powervs)
                export UPGRADE_PRE_RUN_TAGS="@baremetal-upi and ${UPGRADE_PRE_RUN_TAGS}"
                eval "$extrainfoCmd"
                ;;
            alibabacloud)
                export UPGRADE_PRE_RUN_TAGS="@alicloud-${ipixupi} and ${UPGRADE_PRE_RUN_TAGS}"
                ;;
            aws|azure|baremetal|gcp|ibmcloud|nutanix|openstack|vsphere)
                export UPGRADE_PRE_RUN_TAGS="@${platform}-${ipixupi} and ${UPGRADE_PRE_RUN_TAGS}"
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
        other)
	    networktag=''
	    ;;
        *)
	    echo "######Expected network to be SDN/OVN/Other, but got: $networktype"
	    ;;
    esac
    if [[ -n $networktag ]] ; then
        export UPGRADE_PRE_RUN_TAGS="${networktag} and ${UPGRADE_PRE_RUN_TAGS}"
    fi
    echo_upgrade_tags
}
function filter_test_by_sno() {
    local nodeno
    nodeno="$(oc get nodes --no-headers | wc -l)"
    if [[ $nodeno -eq 1 ]] ; then
        export UPGRADE_PRE_RUN_TAGS="@singlenode and ${UPGRADE_PRE_RUN_TAGS}"
    fi
    echo_upgrade_tags
}
function filter_test_by_proxy() {
    local proxy
    proxy="$(oc get proxies.config.openshift.io cluster -o yaml | yq '.spec|(.httpProxy,.httpsProxy)' | uniq)"
    if [[ -n "$proxy" ]] && [[ "$proxy" != 'null' ]] ; then
        export UPGRADE_PRE_RUN_TAGS="@proxy and ${UPGRADE_PRE_RUN_TAGS}"
    fi
    echo_upgrade_tags
}
function filter_test_by_hypershift() {
    local topo
    topo="$(oc get infrastructures.config.openshift.io cluster -o yaml | yq '.status.controlPlaneTopology')"
    if [[ "_${topo}_" = '_External_' ]] ; then
        export UPGRADE_PRE_RUN_TAGS="@hypershift-hosted and ${UPGRADE_PRE_RUN_TAGS}"
    fi
    echo_upgrade_tags
}
function filter_test_by_fips() {
    local data
    data="$(oc get configmap cluster-config-v1 -n kube-system -o yaml | yq '.data')"
    if ! (grep --ignore-case --quiet 'fips' <<< "$data") ; then
        export UPGRADE_PRE_RUN_TAGS="not @fips and ${UPGRADE_PRE_RUN_TAGS}"
    fi
    echo_upgrade_tags
}
function filter_test_by_capability() {
    local enabledcaps xversion yversion
    enabledcaps="$(oc get clusterversion version -o yaml | yq '.status.capabilities.enabledCapabilities[]')"
    IFS='.' read xversion yversion _ < <(oc version -o yaml | yq '.openshiftVersion')
    local v411 v412 v413 v414 v415 v416 v417
    v411="baremetal marketplace openshift-samples"
    v412="${v411} Console Insights Storage CSISnapshot"
    v413="${v412} NodeTuning"
    v414="${v413} MachineAPI Build DeploymentConfig ImageRegistry"
    v415="${v414} OperatorLifecycleManager CloudCredential"
    v416="${v415} CloudControllerManager Ingress"
    v417="${v416}"
    # [console]=console
    # the first `console` is the capability name
    # the second `console` is the tag name in verification-tests
    declare -A tagmaps
    tagmaps=([baremetal]=xxx
             [Build]=workloads
             [CloudControllerManager]=xxx
             [CloudCredential]=xxx
             [Console]=console
             [CSISnapshot]=storage
             [DeploymentConfig]=workloads
             [ImageRegistry]=xxx
             [Ingress]=xxx
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
        4.17)
            versioncaps="$v417"
            ;;
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
                export UPGRADE_PRE_RUN_TAGS="not @${tagmaps[$cap]} and ${UPGRADE_PRE_RUN_TAGS}"
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
    filter_test_by_hypershift
    filter_test_by_proxy
    filter_test_by_sno
    filter_test_by_network
    filter_test_by_platform
    filter_test_by_arch
    filter_test_by_version

    echo_upgrade_tags
}
function test_execution() {
    pushd /verification-tests
    export OPENSHIFT_ENV_OCP4_USER_MANAGER=UpgradeUserManager
    export OPENSHIFT_ENV_OCP4_USER_MANAGER_USERS=${USERS}
    export BUSHSLICER_REPORT_DIR="${ARTIFACT_DIR}"
    set -x
    cucumber --tags "${UPGRADE_PRE_RUN_TAGS} and @upgrade-prepare" -p junit || true
    set +x
    popd
}
function summarize_test_results() {
    # summarize test results
    echo "Summarizing test results..."
    if ! [[ -d "${ARTIFACT_DIR:-'/default-non-exist-dir'}" ]] ; then
        echo "Artifact dir '${ARTIFACT_DIR}' not exist"
        exit 0
    else
        echo "Artifact dir '${ARTIFACT_DIR}' exist"
        ls -lR "${ARTIFACT_DIR}"
        files="$(find "${ARTIFACT_DIR}" -name '*.xml' | wc -l)"
        if [[ "$files" -eq 0 ]] ; then
            echo "There are no JUnit files"
            exit 0
        fi
    fi
    declare -A results=([failures]='0' [errors]='0' [skipped]='0' [tests]='0')
    grep -r -E -h -o 'testsuite.*tests="[0-9]+"[^>]*' "${ARTIFACT_DIR}" > /tmp/zzz-tmp.log || exit 0
    while read row ; do
	for ctype in "${!results[@]}" ; do
            count="$(sed -E "s/.*$ctype=\"([0-9]+)\".*/\1/" <<< $row)"
            if [[ -n $count ]] ; then
                let results[$ctype]+=count || true
            fi
        done
    done < /tmp/zzz-tmp.log

    TEST_RESULT_FILE="${ARTIFACT_DIR}/test-results.yaml"
    cat > "${TEST_RESULT_FILE}" <<- EOF
cucushift-upgrade-prepare:
  total: ${results[tests]}
  failures: ${results[failures]}
  errors: ${results[errors]}
  skipped: ${results[skipped]}
EOF

    if [ ${results[failures]} != 0 ] ; then
        echo '  failingScenarios:' >> "${TEST_RESULT_FILE}"
        readarray -t failingscenarios < <(grep -h -r -E 'cucumber.*features/.*.feature' "${ARTIFACT_DIR}/.." | cut -d':' -f3- | sed -E 's/^( +)//;s/\x1b\[[0-9;]*m$//' | sort)
        for (( i=0; i<${results[failures]}; i++ )) ; do
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
if [[ -z "$UPGRADE_PRE_RUN_TAGS" ]] ; then
    export UPGRADE_PRE_RUN_TAGS="$CUCUSHIFT_FORCE_SKIP_TAGS"
else
    export UPGRADE_PRE_RUN_TAGS="$UPGRADE_PRE_RUN_TAGS and $CUCUSHIFT_FORCE_SKIP_TAGS"
fi

# check if the cluster is ready
set_cluster_access
oc version --client

run_command "oc wait nodes --all --for=condition=Ready=true --timeout=25m"
if [[ $IS_ACTIVE_CLUSTER_OPENSHIFT != "false" ]]; then
    run_command "oc adm wait-for-stable-cluster --minimum-stable-period=5m --timeout=15m"
fi

preparation_for_test
filter_tests
test_execution
summarize_test_results
