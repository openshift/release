#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


function RTenable() {
role=$1
echo -e "\n enable RT on cluster"
oc get nodes -o wide
oc apply -f - <<_EOF
apiVersion: performance.openshift.io/v2
kind: PerformanceProfile
metadata:
  annotations:
    kubeletconfig.experimental: |
      {"podPidsLimit": 16384}
  name: performance
spec:
  cpu:
    isolated: 5-111
    reserved: 0-4
  machineConfigPoolSelector:
    pools.operator.machineconfiguration.openshift.io/$role: ""
  nodeSelector:
    node-role.kubernetes.io/$role: ""
  numa:
    topologyPolicy: restricted
  realTimeKernel:
    enabled: true
_EOF
oc wait --for=condition=Updating --timeout=180s mcp $role
sleep 10m
oc wait --for=condition=Updated --timeout=30m mcp $role
oc get nodes -o wide
}


function RTtest() {
command=$1
read -a command_arr <<< $command
test=${command_arr[0]:2:-2}
test=${test//_/-}

echo "******************************************************************************"
echo "Run RT $test test with command $command"
echo "******************************************************************************"
oc create -f - <<_EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: $test
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: $test
          image: quay.io/ocp-edge-qe/rt-tests@sha256:d0f1cba60f0ce896197139c8d5e04e963b4904b43076dc6018c5857491ff8855
          imagePullPolicy: Always
          command: $command
          securityContext:
            privileged: true
            runAsNonRoot: false
_EOF
pod=$(oc get pod -o name |grep $test)
oc wait $pod --for=jsonpath='{.status.phase}'=Succeeded --timeout=10m
oc logs $pod | tee $ARTIFACT_DIR/RT-$test.log
}

set -x
# Fix user IDs in a container
# ~/fix_uid.sh
oc project
oc project default
ls -la $SHARED_DIR
chmod 666 $SHARED_DIR/kubeconfig
ls -la $SHARED_DIR
id
oc project default

if [ "$SNO_CLUSTER" = "true" ]; then
  RTenable master
else
  RTenable worker
fi

# cp $SHARED_DIR/kubeconfig /tmp/kubeconfig
# export KUBECONFIG=/tmp/kubeconfig
# oc project default

RTtest "[\"pi_stress\", \"--duration=40\", \"--groups=1\"]"
RTtest "[\"rteval\", \"--duration=40\"]"
RTtest "[\"deadline_test\", \"-t 1\", \"-i 100000\"]"