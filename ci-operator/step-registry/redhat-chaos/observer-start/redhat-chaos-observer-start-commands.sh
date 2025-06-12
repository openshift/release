#!/bin/bash

set -o nounset

oc create ns $TEST_NAMESPACE

oc label ns $TEST_NAMESPACE security.openshift.io/scc.podSecurityLabelSync=false pod-security.kubernetes.io/enforce=privileged pod-security.kubernetes.io/audit=privileged pod-security.kubernetes.io/warn=privileged --overwrite

oc apply -f- -n $TEST_NAMESPACE <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${POD_NAME}
  labels:
    app:  observer-status
spec:
  selector:
    matchLabels:
       app: observer-status
  replicas: 1
  strategy:
    type: RollingUpdate
  template:
    metadata:
      name:  ${POD_NAME}
      labels:
        app: observer-status
    spec:
      containers:
      - name: ${POD_NAME}
        image: docker.io/ocpqe/hello-pod
        imagePullPolicy: Always
        securityContext:
          privileged: true
          capabilities: {}
      restartPolicy: Always
      dnsPolicy: ClusterFirst
EOF

oc wait --for=condition=Ready=true po $POD_NAME -n $TEST_NAMESPACE --timeout=300s

oc get pods -n $TEST_NAMESPACE

oc cluster-info