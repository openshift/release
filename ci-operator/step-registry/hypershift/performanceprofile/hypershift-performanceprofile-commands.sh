#!/bin/bash

set -exuo pipefail

CLUSTER_NAME="$(echo -n $PROW_JOB_ID|sha256sum|cut -c-20)"
HYPERSHIFT_NAMESPACE="$(oc get hostedclusters -A -o=jsonpath="{.items[?(@.metadata.name==\"$CLUSTER_NAME\")].metadata.namespace}")"

cat > /tmp/performance_profile.yaml <<EOL
apiVersion: v1
kind: ConfigMap
metadata:
  name: cnf-performanceprofile
  namespace: "${HYPERSHIFT_NAMESPACE}"
data:
  tuning: |
    apiVersion: performance.openshift.io/v2
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
        - amd_iommu=on
      cpu:
        isolated: "${CPU_ISOLATED}"
        reserved: "${CPU_RESERVED}"
      hugepages:
        defaultHugepagesSize: "1G"
        pages:
          - count: ${HUGEPAGES}
            node: 0
            size: 1G
      nodeSelector:
        node-role.kubernetes.io/worker: ''
      realTimeKernel:
        enabled: false
      globallyDisableIrqLoadBalancing: true
EOL

echo "Creating ConfigMap cnf-performanceprofile in namespace ${HYPERSHIFT_NAMESPACE}"
oc create -f /tmp/performance_profile.yaml

oc patch nodepool -n ${HYPERSHIFT_NAMESPACE} ${CLUSTER_NAME} -p '{"spec":{"tuningConfig":[{"name":"cnf-performanceprofile"}]}}' --type=merge

oc wait --for=condition=UpdatingConfig=True nodepool -n ${HYPERSHIFT_NAMESPACE} ${CLUSTER_NAME} --timeout=5m
oc wait --for=condition=UpdatingConfig=False nodepool -n ${HYPERSHIFT_NAMESPACE} ${CLUSTER_NAME} --timeout=30m
oc wait --for=condition=AllNodesHealthy nodepool -n ${HYPERSHIFT_NAMESPACE} ${CLUSTER_NAME} --timeout=5m
