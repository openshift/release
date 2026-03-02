#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

node_role=${APPLY_NODE_ROLE:=worker}
max_cpu=8
isolated_cpu=${COMPUTE_NODE_ISOLATED_CPU:-4}
gcp_pattern="[ncma][1-9]d?-(standard|highcpu|highmem|highgpu)-([0-9]+)"

if [[ ${COMPUTE_NODE_TYPE-"not_provided"} =~ $gcp_pattern ]]
then
  max_cpu=${BASH_REMATCH[2]}
  echo "Using compute node $COMPUTE_NODE_TYPE, setting max vCPU to $max_cpu"
else
  echo "No supported compute node detected, using default max vCPU of $max_cpu"
fi

if [[ "$isolated_cpu" == "$max_cpu" ]]; then
  isolated_cpu=$(( max_cpu / 2))
  echo "max and isolated cpu are equal, setting isolated CPU to $isolated_cpu"
fi

echo "Creating new realtime tuned profile on cluster"
oc create -f - <<EOF
apiVersion: tuned.openshift.io/v1
kind: Tuned
metadata:
  name: ${node_role}-rt
  namespace: openshift-cluster-node-tuning-operator
spec:
  profile:
  - data: |
      [main]
      summary=Optimize for realtime workloads
      include = network-latency

      [variables]
      isolated_cores=$isolated_cpu-$(( max_cpu - 1))
      isolate_managed_irq=Y
      disable_pstate = \${f:cpuinfo_check:GenuineIntel:intel_pstate=disable:AuthenticAMD:amd_pstate=disable:}
      isolated_cores_assert_check = \\\${isolated_cores}
      assert1=\${f:assertion_non_equal:isolated_cores are set:\${isolated_cores}:\${isolated_cores_assert_check}}
      not_isolated_cpumask = \${f:cpulist2hex_invert:\${isolated_cores}}
      isolated_cores_expanded=\${f:cpulist_unpack:\${isolated_cores}}
      isolated_cpumask=\${f:cpulist2hex:\${isolated_cores_expanded}}
      isolated_cores_online_expanded=\${f:cpulist_online:\${isolated_cores}}
      assert2=\${f:assertion:isolated_cores contains online CPU(s):\${isolated_cores_expanded}:\${isolated_cores_online_expanded}}
      managed_irq=\${f:regex_search_ternary:\${isolate_managed_irq}:\b[y,Y,1,t,T]\b:managed_irq,:}

      [net]
      channels=combined \${f:check_net_queue_count:\${netdev_queue_count}}

      [sysctl]
      kernel.sched_rt_runtime_us = -1

      [service]
      stalld_service="service.stalld=start,enable"

      [sysfs]
      /sys/bus/workqueue/devices/writeback/cpumask = \${not_isolated_cpumask}
      /sys/devices/virtual/workqueue/cpumask = \${not_isolated_cpumask}
      /sys/devices/virtual/workqueue/*/cpumask = \${not_isolated_cpumask}
      /sys/devices/system/machinecheck/machinecheck*/ignore_ce = 1

      [bootloader]
      cmdline_realtime=+isolcpus=\${managed_irq}\${isolated_cores} \${disable_pstate} nosoftlockup nohz_full=\${isolated_cores} rcu_nocbs=\${isolated_cores} nohz=on audit=0

      [irqbalance]
      banned_cpus=\${isolated_cores}
    name: openshift-node-performance-manual
  recommend:
  - machineConfigLabels:
      machineconfiguration.openshift.io/role: ${node_role}
    operand:
      debug: false
    priority: 20
    profile: openshift-node-performance-manual
EOF

echo "waiting for mcp/${node_role} condition=Updating timeout=5m"
oc wait mcp/${node_role} --for condition=Updating --timeout=5m

# When applying this configuration to the master node for single node
# we need to wait for the master node to restart before we attempt to call out to the API Server
if [[ "$node_role" == "master" ]]; then
  seconds=600
  echo "master node is updating, waiting $seconds seconds for master node to restart"
  sleep $seconds
fi


echo "waiting for mcp/${node_role} condition=Updated timeout=40m"
oc wait mcp/${node_role} --for condition=Updated --timeout=40m

seconds=120
echo "waiting $seconds seconds to give some delay before collecting metrics"
sleep $seconds
