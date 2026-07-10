#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release

ISOLATED_CORES=$(cat ${CLUSTER_PROFILE_DIR}/isolated_cores)
RESERVED_CORES=$(cat ${CLUSTER_PROFILE_DIR}/reserved_cores)

oc config view
oc projects

# Create the performance profile setup
if [[ $TYPE == "sno" ]]; then
  MCP_NAME="master"
else
  MCP_NAME="worker"
fi

oc patch --type=merge --patch='{"spec":{"maxUnavailable":"100%"}}' machineconfigpool/${MCP_NAME}

cat << EOF| oc apply -f -
apiVersion: performance.openshift.io/v2
kind: PerformanceProfile
metadata:
  name: cpt-pao
  annotations:
    kubeletconfig.experimental: |
      {"allowedUnsafeSysctls":["net.ipv6.conf.all.accept_ra"],"maxPods":${MAX_PODS}}
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
    pools.operator.machineconfiguration.openshift.io/${MCP_NAME}: ''
  nodeSelector:
    node-role.kubernetes.io/${MCP_NAME}: ""
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

# Added a 5 minutes delay as Performance operator will take sometime to update updatedMachineCount in case of MNO cluster
# Added a 15 minutes delay as SNO cluster will go for reboot after applying the performance profile
if [[ $TYPE == "sno" ]]; then
  sleep 900
else
  sleep 300
fi

oc adm wait-for-stable-cluster --minimum-stable-period=2m --timeout=40m
