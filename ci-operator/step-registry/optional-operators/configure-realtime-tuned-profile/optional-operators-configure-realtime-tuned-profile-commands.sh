#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

node_role=${APPLY_NODE_ROLE:=worker}
max_cpu=8
isolated_cpu=${COMPUTE_NODE_ISOLATED_CPU:-4}
sched_rt_runtime_us=-1
stalld_service="service.stalld=start,enable"
gcp_pattern="[n|c|m|a]{1}[1-9]{1}d?-(standard|highcpu|highmem|highgpu){1}-([0-9]+)"

# Currently RT is only supported on GCP
# if non supported node type provided, will default to 4 isolated and 8 max CPU usage
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

if [ ${STALLD_ENABLED:="true"} != "true" ]
then
  echo "disabling stalld and setting default realtime timeout"
  sched_rt_runtime_us=950000
  stalld_service=""
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
      summary=Openshift node optimized for deterministic performance at the cost of increased power consumption, focused on low latency network performance. Based on Tuned 2.11 and Cluster node tuning (oc 4.5)
      include=openshift-node,cpu-partitioning

      [variables]
      isolated_cores=$isolated_cpu-$(( max_cpu - 1))
      not_isolated_cores_expanded=\${f:cpulist_invert:\${isolated_cores_expanded}}

      [cpu]
      force_latency=cstate.id:1|3
      governor=performance
      energy_perf_bias=performance
      min_perf_pct=100

      [service]
      $stalld_service

      [vm]
      transparent_hugepages=never

      [irqbalance]
      banned_cpus=""

      [scheduler]
      runtime=0
      group.ksoftirqd=0:f:11:*:ksoftirqd.*
      group.rcuc=0:f:11:*:rcuc.*
      default_irq_smp_affinity = ignore

      [sysctl]
      kernel.hung_task_timeout_secs = 600
      kernel.nmi_watchdog = 0
      kernel.sched_rt_runtime_us = $sched_rt_runtime_us
      kernel.timer_migration = 0
      kernel.numa_balancing=0
      net.core.busy_read=50
      net.core.busy_poll=50
      net.ipv4.tcp_fastopen=3
      vm.stat_interval = 10
      kernel.sched_min_granularity_ns=10000000
      vm.dirty_ratio=10
      vm.dirty_background_ratio=3
      vm.swappiness=10
      kernel.sched_migration_cost_ns=5000000

      [selinux]
      avc_cache_threshold=8192

      [net]
      nf_conntrack_hashsize=131072

      [bootloader]
      # set empty values to disable RHEL initrd setting in cpu-partitioning
      initrd_remove_dir=
      initrd_dst_img=
      initrd_add_dir=
      # overrides cpu-partitioning cmdline
      cmdline_cpu_part=+nohz=on rcu_nocbs=\${isolated_cores} tuned.non_isolcpus=\${not_isolated_cpumask} intel_pstate=disable nosoftlockup
      cmdline_realtime=+intel_iommu=on iommu=pt isolcpus=managed_irq,\${isolated_cores} systemd.cpu_affinity=\${not_isolated_cores_expanded}
      cmdline_additionalArg=+ nmi_watchdog=0 audit=0 mce=off processor.max_cstate=1 idle=poll intel_idle.max_cstate=0 nohz_full=\${isolated_cores}
      cmdline_network_latency=skew_tick=1 tsc=reliable rcupdate.rcu_normal_after_boot=1
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
