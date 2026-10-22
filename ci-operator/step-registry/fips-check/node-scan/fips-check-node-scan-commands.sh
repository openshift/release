#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

function set_proxy () {
    if test -s "${SHARED_DIR}/proxy-conf.sh" ; then
        echo "setting the proxy"
        echo "source ${SHARED_DIR}/proxy-conf.sh"
        source "${SHARED_DIR}/proxy-conf.sh"
    else
        echo "no proxy setting."
    fi
}

function run_command() {
    local CMD="$1"
    echo "Running Command: ${CMD}"
    eval "${CMD}"
}

set_proxy
run_command "oc whoami"
run_command "oc version -o yaml"
pass=true

# skip for ARM64
mapfile -t node_archs< <(oc get nodes -o jsonpath --template '{range .items[*]}{.status.nodeInfo.architecture}{"\n"}{end}' | sort -R | uniq -d)
echo "The architectures included in the current cluster nodes are ${node_archs[*]}"
NON_SUPPORTED_ARCHES=(arm64)
for arch in "${node_archs[@]}"; do
    if [[ "${NON_SUPPORTED_ARCHES[*]}" =~ $arch ]]; then
        echo "Skip this test since it doesn't support $arch."
        exit 0
    fi
done

# get a master node
master_node_0=$(oc get node -l node-role.kubernetes.io/master= --no-headers | grep -Ev "NotReady|SchedulingDisabled"| awk '{print $1}' | awk 'NR==1{print}')
if [[ -z $master_node_0 ]]; then
    echo "Error master node0 name is null!"
    pass=false
fi
# create a ns
project="node-scan-$RANDOM"
run_command "oc new-project $project --skip-config-write"
if [ $? == 0 ]; then
    echo "create $project project successfully" 
else
    echo "Fail to create $project project."
    pass=false
fi
# check whether it is disconnected cluster
run_command "oc extract secret/pull-secret -n openshift-config --confirm --to /tmp"; ret=$?
if [[ $ret -eq 0 ]]; then
    auths=`cat /tmp/.dockerconfigjson`
    if [[ $auths =~ "5000" ]]; then
        echo "This is a disconnected env, skip it."
        exit 0
    fi
fi

# run node scan and check the result
report="/tmp/fips-check-node-scan.log"
oc label namespace "$project" security.openshift.io/scc.podSecurityLabelSync=false pod-security.kubernetes.io/enforce=privileged pod-security.kubernetes.io/audit=privileged pod-security.kubernetes.io/warn=privileged --overwrite=true || true
cluster_http_proxy=$(oc get proxy cluster -o=jsonpath='{.spec.httpProxy}')
cluster_https_proxy=$(oc get proxy cluster -o=jsonpath='{.spec.httpProxy}')
oc --request-timeout=300s -n "$project" debug node/"$master_node_0" -- chroot /host bash -c "export http_proxy=$cluster_http_proxy; export https_proxy=$cluster_https_proxy; podman run --authfile /var/lib/kubelet/config.json --privileged -i -v /:/myroot quay-proxy.ci.openshift.org/openshift/ci:ci_check-payload_latest scan node --root  /myroot &> $report" || true
out=$(oc --request-timeout=300s -n "$project" debug node/"$master_node_0" -- chroot /host bash -c "cat /$report" || true)
echo "The report is: $out"
oc delete ns $project || true
res=$(echo "$out" | grep -E 'Failure Report|Successful run with warnings|Warning Report' || true)
if [[ -n $res ]];then
    echo "The result is: $res"
    pass=false
fi

# generate report
echo "Generating the Junit for fips check node scan"
filename="junit_fips-check-node-scan"
testsuite="fips-check-node-scan"
subteam="Security_and_Compliance"
if $pass; then
    cat >"${ARTIFACT_DIR}/${filename}.xml" <<EOF
    <testsuite name="${testsuite}" failures="0" errors="0" skipped="0" tests="1" time="$SECONDS">
        <testcase name="${subteam}:Node scan of fips check should succeedded or skipped"/>
    </testsuite>
EOF
else
    cat >"${ARTIFACT_DIR}/${filename}.xml" <<EOF
    <testsuite name="${testsuite}" failures="1" errors="0" skipped="0" tests="1" time="$SECONDS">
        <testcase name="${subteam}:Node scan of fips check should succeedded or skipped">
            <failure message="">
                Node scan failed due to errors or warnings:
                <![CDATA[$res]]>
            </failure>
        </testcase>
    </testsuite>
EOF
fi
