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

function create_pod() {
    cat <<EOF | oc create -f -
    apiVersion: v1
    kind: Pod
    metadata:
      name: $pod_name
      namespace: $project
    spec:
      containers:
      - name: $pod_name
        image: $image
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop:
            - ALL
      restartPolicy: OnFailure
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        seccompProfile:
          type: RuntimeDefault
EOF
    if [ $? == 0 ]; then
        echo "create the $pod_name successfully" 
    else
        echo "!!! fail to create $pod_name pod."
        pass=false
    fi
}

function check_pod_log() {
    index=`echo ${pod_name: -5:-4}`
    # echo "index: $index"
    log=`oc -n $project logs $pod_name --tail=2`
    if $fips_enabled; then
        if [[ $index = 1 && $log =~ "FIPS mode is enabled, but the required OpenSSL library is not available" ]]; then
            echo "PASS"
        elif [[ $index = 2 && $log =~ "FIPS mode is enabled, but this binary is not compiled with FIPS compliant mode enabled" ]]; then
            echo "PASS"
        elif [[ $index = 3 && $log =~ "FIPS mode is enabled, but this binary is not compiled with FIPS compliant mode enabled" ]]; then
            echo "PASS"
        elif [[ $index = 4 && $log =~ "This is a secret" ]]; then
            echo "PASS"
        else
            echo "The output of $pod_name is not as expected: $log"
            pass=false
        fi
    else
        if [[ $log =~ "This is a secret" ]]; then
            echo "PASS"
        else
            echo "Fail! the output of $pod_name is not as expected: $log"
            pass=false
        fi
    fi
}

images=("quay.io/openshifttest/fips-or-die:go1.16-s1-1.2.0"
    "quay.io/openshifttest/fips-or-die:go1.16-s2-1.2.0"
    "quay.io/openshifttest/fips-or-die:go1.16-s3-1.2.0"
    "quay.io/openshifttest/fips-or-die:go1.16-s4-1.2.0"
    "quay.io/openshifttest/fips-or-die:go1.17-s1-1.2.0"
    "quay.io/openshifttest/fips-or-die:go1.17-s2-1.2.0"
    "quay.io/openshifttest/fips-or-die:go1.17-s3-1.2.0"
    "quay.io/openshifttest/fips-or-die:go1.17-s4-1.2.0"
    "quay.io/openshifttest/fips-or-die:go1.18-s1-1.2.0"
    "quay.io/openshifttest/fips-or-die:go1.18-s2-1.2.0"
    "quay.io/openshifttest/fips-or-die:go1.18-s3-1.2.0"
    "quay.io/openshifttest/fips-or-die:go1.18-s4-1.2.0"
    "quay.io/openshifttest/fips-or-die:go1.19-el8-s1-1.2.0"
    "quay.io/openshifttest/fips-or-die:go1.19-el8-s2-1.2.0"
    "quay.io/openshifttest/fips-or-die:go1.19-el8-s3-1.2.0"
    "quay.io/openshifttest/fips-or-die:go1.19-el8-s4-1.2.0"
    "quay.io/openshifttest/fips-or-die:go1.19-el9-s1-1.2.0"
    "quay.io/openshifttest/fips-or-die:go1.19-el9-s2-1.2.0"
    "quay.io/openshifttest/fips-or-die:go1.19-el9-s3-1.2.0"
    "quay.io/openshifttest/fips-or-die:go1.19-el9-s4-1.2.0"
    "quay.io/openshifttest/fips-or-die:go1.20-el8-s1-1.2.0"
    "quay.io/openshifttest/fips-or-die:go1.20-el8-s2-1.2.0"
    "quay.io/openshifttest/fips-or-die:go1.20-el8-s3-1.2.0"
    "quay.io/openshifttest/fips-or-die:go1.20-el8-s4-1.2.0"
    "quay.io/openshifttest/fips-or-die:go1.20-el9-s1-1.2.0"
    "quay.io/openshifttest/fips-or-die:go1.20-el9-s2-1.2.0"
    "quay.io/openshifttest/fips-or-die:go1.20-el9-s3-1.2.0"
    "quay.io/openshifttest/fips-or-die:go1.20-el9-s4-1.2.0"
    )

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

mapfile -t node_archs< <(oc get nodes -o jsonpath --template '{range .items[*]}{.status.nodeInfo.architecture}{"\n"}{end}' | sort -R | uniq -d)
echo "The architectures included in the current cluster nodes are ${node_archs[*]}"
### Skip ppc64le and s390x temporarily becasue the test images are not manifest list images now.
NON_SUPPORTED_ARCHES=(arm64)
for arch in "${node_archs[@]}"; do
  if [[ "${NON_SUPPORTED_ARCHES[*]}" =~ $arch ]]; then
      echo "Skip this test since it doesn't support $arch."
      exit 0
  fi
done

project="fips-or-die-$RANDOM"
run_command "oc new-project $project"
if [ $? == 0 ]; then
    echo "create $project project successfully" 
else
    echo "fail to create $project project."
fi

# check if FIPS enabled
fips_enabled=false
node_name=`oc get node -l node-role.kubernetes.io/master= -o=jsonpath="{.items[0].metadata.name}"`
str=`oc -n default debug node/$node_name -- chroot /host fips-mode-setup --check`
if [[ $str =~ "FIPS mode is enabled" ]]
then
    fips_enabled=true
fi
echo "Cluster FIPS enabled: $fips_enabled"

pass=true

# create pods
for image in "${images[@]}"; do 
    echo "image: $image"
    tag=$(echo $image | cut -d: -f2)
    echo "tag: $tag"
    pod_name=${tag//./}
    echo "pod name: $pod_name"
    create_pod
    sleep 1
done

# check pod's log
for image in "${images[@]}"; do 
    tag=$(echo $image | cut -d: -f2)
    pod_name=${tag//./}
    echo "checking Pod $pod_name"
    # waiting for pod ready
    COUNTER=0
    while [ $COUNTER -lt 600 ]
    do
        sleep 20
        COUNTER=`expr $COUNTER + 20`
        echo "waiting ${COUNTER}s"
        STATUS=`oc -n $project get pod $pod_name -o=jsonpath="{.status.phase}"`
        if [[ $STATUS = "Running" ]]; then
            echo "Pod $pod_name is Running."
            break
        fi
    done
    check_pod_log
done

mkdir -p "${ARTIFACT_DIR}/junit"
echo "Generating the Junit for fips-or-die scan"
filename="junit_fips-or-die"
testsuite="fips-or-die"
subteam="Security_and_Compliance"
if $pass; then
    cat >"${ARTIFACT_DIR}/${filename}.xml" <<EOF
    <testsuite name="${testsuite}" failures="0" errors="0" skipped="0" tests="1" time="$SECONDS">
        <testcase name="${subteam}:Fips-or-die check should succeedded or skipped"/>
    </testsuite>
EOF
else
    cat >"${ARTIFACT_DIR}/${filename}.xml" <<EOF
    <testsuite name="${testsuite}" failures="1" errors="0" skipped="0" tests="1" time="$SECONDS">
        <testcase name="${subteam}:Fips-or-die check should succeedded or skipped">
            <failure message="">Test fail, please check full log in Prow.</failure>
            <system-out>
            $log
            </system-out>
        </testcase>
    </testsuite>
EOF
fi
