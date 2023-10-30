#!/bin/bash
set -e
set -u
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

# skip test for disconnected clusters
run_command "oc extract secret/pull-secret -n openshift-config --confirm --to /tmp"; ret=$?
if [[ $ret -eq 0 ]]; then
    auths=`cat /tmp/.dockerconfigjson`
    if [[ $auths =~ "5000" ]]; then
        echo "This is a disconnected env, skip it."
        exit 0
    fi
fi

#skip for ARM64
mapfile -t node_archs< <(oc get nodes -o jsonpath --template '{range .items[*]}{.status.nodeInfo.architecture}{"\n"}{end}' | sort -R | uniq -d)
echo "The architectures included in the current cluster nodes are ${node_archs[*]}"
NON_SUPPORTED_ARCHES=(arm64)
for arch in "${node_archs[@]}"; do
  if [[ "${NON_SUPPORTED_ARCHES[*]}" =~ $arch ]]; then
      echo "Skip this test since it doesn't support $arch."
      exit 0
  fi
done

#get a master node
pass=false
master_node_0=`oc get node -l node-role.kubernetes.io/master= --no-headers | grep -Ev "NotReady|SchedulingDisabled"| awk '{print $1}' | awk 'NR==1{print}'`
if [[ -z $master_node_0 ]]; then
    echo "Error master node0 name is null!\n."
    exit
fi

#create a ns and a debug pod
project="node-scan-$RANDOM"
run_command "oc new-project $project"
if [ $? == 0 ]; then
    echo "create $project project successfully" 
else
    echo "fail to create $project project."
fi
pod="debug-pod-$RANDOM"
oc  -n $project debug  no/${master_node_0} --dry-run=client -o yaml > /tmp/$project-$pod.yaml
if [ $? == 0 ]; then
    sed -e "s/^  name: .*$/  name: $pod/" -e 's/value: "900"/value: "90000"/' /tmp/$project-$pod.yaml | oc create -f -
    echo "sleep 10s to wait debug-pod ready."
    COUNTER=0
    while [ $COUNTER -lt 60 ]
    do
        sleep 10
        STATUS=`oc -n $project get pod $pod -o=jsonpath="{.status.phase}"`
        if [[ $STATUS = "Running" ]]; then
            echo "Pod $pod is Running."
            break
        fi
        COUNTER=`expr $COUNTER + 10`
        echo "waiting ${COUNTER}s"
    done
    if [[ "$COUNTER" == 60 ]];then
        echo "Time out! Pod is not Running"
        exit
    fi
else
    echo "fail to get dry-run debug file"
    exit
fi

# run node scan and check the result
report="/tmp/fips-check-node-scan.log"
oc -n $project cp /tmp/.dockerconfigjson $pod:/host/tmp/node_scan_auth.json >/dev/null 2>&1
sleep 7200
oc -n $project exec $pod -- chroot /host bash -x -c "podman run --authfile /tmp/node_scan_auth.json --privileged -i -v /:/myroot registry.ci.openshift.org/ci/check-payload:latest scan node --root  /myroot 2>&1> $report"
out=$(oc -n $project exec $pod -- cat /host/$report || true)
echo "the report is: $out"
sub='Successful run'
if [[ "$out" == *"$sub"* ]]; then
   pass=true
else
   pass=false
fi

# clean up
oc delete pod $pod
oc delete ns $project

# generate report
mkdir -p "${ARTIFACT_DIR}/junit"
if $pass; then
    echo "All tests pass!"
    cat >"${ARTIFACT_DIR}/junit/fips-check-node-scan.xml" <<EOF
    <testsuite name="fips scan" tests="1" failures="0">
        <testcase name="fips-check-node-scan"/>
        <succeed message="">Test pass, check the details from below</succeed>
        <system-out>
          $out
        </system-out>
    </testsuite>
EOF
else
    echo "Test fail, please check log."
    cat >"${ARTIFACT_DIR}/junit/fips-check-node-scan.xml" <<EOF
    <testsuite name="fips scan" tests="1" failures="1">
      <testcase name="fips-check-node-scan">
        <failure message="">Test fail, check the details from below</failure>
        <system-out>
          $out
        </system-out>
      </testcase>
    </testsuite>
EOF
fi
