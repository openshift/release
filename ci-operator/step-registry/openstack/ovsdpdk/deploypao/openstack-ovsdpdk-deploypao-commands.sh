#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail



## Configure Performance Addon Operator
## https://docs.openshift.com/container-platform/4.9/scalability_and_performance/cnf-performance-addon-operator-for-low-latency-nodes.html

# create operator namespace
cat > 01-pao-namespace.yaml <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-performance-addon-operator
  annotations:
    workload.openshift.io/allowed: management
EOF
echo "Creating Performance Addon Operator namespace"
oc create -f 01-pao-namespace.yaml

#Create operator group
cat > 02-pao-operatorgroup.yaml <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-performance-addon-operator
  namespace: openshift-performance-addon-operator
EOF
echo "Creating Performance Addon Operator group"
oc create -f 02-pao-operatorgroup.yaml

#Create operator subscription
channel=$(oc get packagemanifest performance-addon-operator -n openshift-marketplace -o jsonpath='{.status.defaultChannel}')
cat > 03-pao-subscription.yaml <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-performance-addon-operator-subscription
  namespace: openshift-performance-addon-operator
spec:
  channel: "${channel}"
  name: performance-addon-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
echo "Creating Performance Addon Operator subscription"
oc create -f 03-pao-subscription.yaml

## Creating a Performance profile
cat > 04-performance-profile.yaml <<EOF
apiVersion: performance.openshift.io/v1
kind: PerformanceProfile
metadata:
  name: cnf-performanceprofile
spec:
  additionalKernelArgs:
    - nmi_watchdog=0
    - audit=0
    - mce=off
    - processor.max_cstate=1
    - idle=poll
    - intel_idle.max_cstate=0
    - default_hugepagesz=1GB
    - hugepagesz=1G
  cpu:
    isolated: 2-3
    reserved: 0-1
  hugepages:
    defaultHugepagesSize: 1G
    pages:
      - count: $HUGEPAGES
        node: 0
        size: 1G
  nodeSelector:
    node-role.kubernetes.io/worker: ''
  realTimeKernel:
    enabled: false
EOF
echo "Creating Performance Profile"
oc create -f 04-performance-profile.yaml
