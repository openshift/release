#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


function RTtest() {
command=$1
read -a command_arr <<< $command
test=${command_arr[0]:1:-1}

echo -e "Run RT ${command[0]} test \n"
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
oc logs $pod 2>&1 | tee ${ARTIFACT_DIR}/RT-$test.log
}



echo "**********************************************************************"
oc get co
echo "**********************************************************************"

echo -e "enable RT on cluster \n"
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
    pools.operator.machineconfiguration.openshift.io/master: ""
  nodeSelector:
    node-role.kubernetes.io/master: ""
  numa:
    topologyPolicy: restricted
  realTimeKernel:
    enabled: true
_EOF
oc wait --for=condition=Updating --timeout=180s mcp master
sleep 10m
oc wait --for=condition=Updated --timeout=30m mcp master
oc get nodes -o wide


cp $SHARED_DIR/kubeconfig /output/kubeconfig
export KUBECONFIG=/output/kubeconfig
oc project default

RTtest "["pi_stress", "--duration=40", "--groups=1"]"
RTtest "["rteval", "--duration=40"]"
RTtest "["deadline_test", "-t 1", "-i 100000"]"