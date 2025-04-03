#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release

if [ ${BAREMETAL} == "true" ]; then
  SSH_ARGS="-i /bm/jh_priv_ssh_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"
  bastion="$(cat /bm/address)"
  # Copy over the kubeconfig
  if [ ! -f "${SHARED_DIR}/kubeconfig" ]; then
    ssh ${SSH_ARGS} root@$bastion "cat ${KUBECONFIG_PATH}" > /tmp/kubeconfig
    export KUBECONFIG=/tmp/kubeconfig
  else
    export KUBECONFIG=${SHARED_DIR}/kubeconfig
  fi
  # Setup socks proxy
  ssh ${SSH_ARGS} root@$bastion -fNT -D 12345
  export https_proxy=socks5://localhost:12345
  export http_proxy=socks5://localhost:12345
  oc --kubeconfig="$KUBECONFIG" config set-cluster bm --proxy-url=socks5://localhost:12345
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

kubectl wait --for jsonpath='{.status.updatedMachineCount}'="$(oc get node --no-headers -l node-role.kubernetes.io/worker= | wc -l)" --timeout=30m mcp worker
oc adm wait-for-stable-cluster --minimum-stable-period=2m --timeout=20m

if [ ${BAREMETAL} == "true" ]; then
  # kill the ssh tunnel so the job completes
  pkill ssh
fi
