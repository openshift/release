#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Creating new realtime tuned profile on cluster"
oc create -f - <<EOF
apiVersion: tuned.openshift.io/v1
kind: Tuned
metadata:
  name: worker-rt
  namespace: openshift-cluster-node-tuning-operator
spec:
  profile:
  - data: |
      [main]
      summary=Openshift node optimized for deterministic performance at the cost of increased power consumption, focused on low latency network performance. Based on Tuned 2.11 and Cluster node tuning (oc 4.5)
      include=openshift-node,cpu-partitioning

      [variables]
      isolated_cores=2-7
      not_isolated_cores_expanded=0-1

      [cpu]
      force_latency=cstate.id:1|3
      governor=performance
      energy_perf_bias=performance
      min_perf_pct=100

      [service]
      service.stalld=start,enable

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
      kernel.sched_rt_runtime_us = -1
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
      cmdline_cpu_part=+nohz=on rcu_nocbs=2-7 tuned.non_isolcpus=00000011 intel_pstate=disable nosoftlockup
      cmdline_realtime=+tsc=nowatchdog intel_iommu=on iommu=pt isolcpus=managed_irq,2-7 systemd.cpu_affinity=0-1
      cmdline_additionalArg=+ nmi_watchdog=0 audit=0 mce=off processor.max_cstate=1 idle=poll intel_idle.max_cstate=0
    name: openshift-node-performance-manual
  recommend:
  - machineConfigLabels:
      machineconfiguration.openshift.io/role: worker
    operand:
      debug: false
    priority: 20
    profile: openshift-node-performance-manual
EOF

oc wait mcp/worker --for condition=Updating --timeout=5m
oc wait mcp/worker --for condition=Updated --timeout=30m

# Sleep two minutes to give some delay time before collecting metrics
sleep 120
