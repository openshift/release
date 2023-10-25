#!/bin/bash
set -e
set -u
set -o pipefail

function set_proxy () {
    if test -s "${SHARED_DIR}/proxy-conf.sh" ; then
        echo "setting the proxy"
        # cat "${SHARED_DIR}/proxy-conf.sh"
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

run_command "oc extract secret/pull-secret -n openshift-config --confirm --to /tmp"; ret=$?
if [[ $ret -eq 0 ]]; then
    auths=`cat /tmp/.dockerconfigjson`
    if [[ $auths =~ "5000" ]]; then
        echo "This is a disconnected env, skip it."
        exit 0
    fi
fi
move ~/.ssh/config.json ~/.ssh/config.json.bak
cp  /tmp/.dockerconfigjson ~/.ssh/config.json

mapfile -t node_archs< <(oc get nodes -o jsonpath --template '{range .items[*]}{.status.nodeInfo.architecture}{"\n"}{end}' | sort -R | uniq -d)
echo "The architectures included in the current cluster nodes are ${node_archs[*]}"
# Skip arm arch
NON_SUPPORTED_ARCHES=(arm64)
for arch in "${node_archs[@]}"; do
  if [[ "${NON_SUPPORTED_ARCHES[*]}" =~ $arch ]]; then
      echo "Skip this test since it doesn't support $arch."
      exit 0
  fi
done

pass=false
payload_name=`oc get clusterversion version -ojsonpath='{.status.history[?(@.state=="Completed")].image}'`
report="/tmp/payload_scan_report.txt"
tmp_version=`echo ${payload_name#*:}`
version=${tmp_version:0:4}
./check-payload scan payload -V $version  --url $payload_name --output-file $report
move ~/.ssh/config.json.bak ~/.ssh/config.json
log=`cat $report`
res=`grep "Successful run" $report`
if [[ -z "$res" ]] ; then
    pass=true
else
    pass=false
done

mkdir -p "${ARTIFACT_DIR}/junit"
if $pass; then
    echo "All tests pass!"
    cat >"${ARTIFACT_DIR}/junit/payload-scan.xml" <<EOF
    <testsuite name="fips" tests="1" failures="0">
        <testcase name="payload-scan"/>
        <succeed message="">Test pass, check the details from below</succeed>
        <system-out>
          $log
        </system-out>
    </testsuite>
EOF
else
    echo "Test fail, please check log."
    cat >"${ARTIFACT_DIR}/junit/payload-scan.xml" <<EOF
    <testsuite name="fips" tests="1" failures="1">
      <testcase name="payload-scan">
        <failure message="">Test fail, check the details from below</failure>
        <system-out>
          $log
        </system-out>
      </testcase>
    </testsuite>
EOF
fi
