#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release

if [ ${BAREMETAL} == "true" ]; then
  bastion="$(cat /bm/address)"
  # Copy over the kubeconfig
  sshpass -p "$(cat /bm/login)" ssh -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null root@$bastion "cat ~/bm/kubeconfig" > /tmp/kubeconfig
  # Setup socks proxy
  sshpass -p "$(cat /bm/login)" ssh -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null root@$bastion -fNT -D 12345
  export KUBECONFIG=/tmp/kubeconfig
  export https_proxy=socks5://localhost:12345
  export http_proxy=socks5://localhost:12345
  oc --kubeconfig=/tmp/kubeconfig config set-cluster bm --proxy-url=socks5://localhost:12345
fi

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
    # node0 CPUs: 0,2,..,126
    # node1 CPUs: 1,3,..,127
    # siblings: (0,64), (1,65)...
    isolated: 2-63,66-127
    reserved: 0,1,64,65
  globallyDisableIrqLoadBalancing: false
  hugepages:
    defaultHugepagesSize: 1G
    pages:
    # 32GB per numa node
    - count: 64
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
kubectl wait --for jsonpath='{.status.updatedMachineCount}'=$(oc get node --no-headers -l node-role.kubernetes.io/worker= | wc -l) --timeout=10m mcp worker

if [ ${BAREMETAL} == "true" ]; then
  # kill the ssh tunnel so the job completes
  pkill ssh
fi
