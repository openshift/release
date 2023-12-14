#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


echo "**********************************************************************"
oc get co
echo "**********************************************************************"

oc apply -f - <<_EOF
apiVersion: performance.openshift.io/v2
kind: PerformanceProfile
metadata:
  name: performance
spec:
  cpu:
    isolated: 2-39,48-79
    offlined: 42-47
    reserved: 0-1,40-41
  machineConfigPoolSelector:
    machineconfiguration.openshift.io/role: master
  nodeSelector:
    node-role.kubernetes.io/master: ""
  numa:
    topologyPolicy: restricted
  realTimeKernel:
    enabled: true
_EOF

oc wait --for=condition=Updating --timeout=180s mcp master
oc wait --for=condition=Updated --timeout=60m mcp master

test="pi-stress"
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
          command: ["pi_stress", "--duration=40", "--groups=1"]
          securityContext:
            privileged: true
            runAsNonRoot: false
_EOF

pod=$(oc get pod -oname|grep $test)
oc wait $pod --for=jsonpath='{.status.phase}'=Succeeded --timeout=10m
oc logs $pod
