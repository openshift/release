#!/bin/bash

set -o nounset

oc create ns $TEST_NAMESPACE

oc label ns $TEST_NAMESPACE security.openshift.io/scc.podSecurityLabelSync=false pod-security.kubernetes.io/enforce=privileged pod-security.kubernetes.io/audit=privileged pod-security.kubernetes.io/warn=privileged --overwrite

oc apply -f- -n $TEST_NAMESPACE <<EOF
kind: Pod
apiVersion: v1
metadata:
  name: $POD_NAME
  creationTimestamp: 
  labels:
    name: pause-amd64
spec:
  containers:
  - name: pause-amd64
    image: docker.io/ocpqe/hello-pod
    securityContext:
      capabilities: {}
      privileged: true
  restartPolicy: Always
  dnsPolicy: ClusterFirst
EOF


oc get pods -n $TEST_NAMESPACE

oc cluster-info