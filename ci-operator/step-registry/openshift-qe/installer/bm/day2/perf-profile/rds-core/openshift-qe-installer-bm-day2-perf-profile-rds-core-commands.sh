#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release

oc config view
oc projects

# Create the performance profile setup

oc patch --type=merge --patch='{"spec":{"maxUnavailable":"100%"}}' machineconfigpool/worker

cat << EOF| oc apply -f -
apiVersion: performance.openshift.io/v2
kind: PerformanceProfile
metadata:
  name: cpt-pao
  annotations:
    kubeletconfig.experimental: |
      {"allowedUnsafeSysctls":["net.ipv6.conf.all.accept_ra"]}
spec:
  cpu:
    isolated: ${ISOLATED_CORES}
    reserved: ${RESERVED_CORES}
  globallyDisableIrqLoadBalancing: false
  hugepages:
    defaultHugepagesSize: 1G
    pages:
    - count: ${HUGEPAGES_COUNT}
      size: 1G
  machineConfigPoolSelector:
    pools.operator.machineconfiguration.openshift.io/worker: ''
  nodeSelector:
    node-role.kubernetes.io/worker: ""
  workloadHints:
    realTime: false
    highPowerConsumption: false
    perPodPowerManagement: true
  realTimeKernel:
    enabled: false
  numa:
    # All guaranteed QoS containers get resources from a single NUMA node
    topologyPolicy: "single-numa-node"
  net:
    userLevelNetworking: false
EOF

sleep 60
kubectl wait --for jsonpath='{.status.updatedMachineCount}'="$(oc get node --no-headers -l node-role.kubernetes.io/worker= | wc -l)" --timeout=30m mcp worker