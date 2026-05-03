# System Comparison: Beaker vs OFCIR (AWS EC2)

## Summary

This document compares the hardware and software configuration between:
- **Beaker**: Red Hat lab machine (rdu-infra-edge-07) - Tests PASS
- **OFCIR**: AWS EC2 instances (e.g., ip-172-31-1-192.us-east-2) - Tests FAIL

## Beaker Machine (PASSING)

### Hardware
- **CPU**: Intel Xeon Gold 5218R @ 2.10GHz
  - 80 CPUs (2 sockets x 20 cores x 2 threads)
  - CPU family: 6, Model: 85, Stepping: 7
  - CPU max MHz: 4000.0000
  - CPU min MHz: 800.0000
  
- **Memory**: 376 GB total RAM
  - Used: 201 GB
  - Available: 174 GB
  - Swap: 4 GB (1.1 GB used)
  - Swappiness: 60

- **Disk**: 
  - System disks: 2x Dell PERC H740P Mini (446.6G each, RAID)
  - Data disks: 2x Dell Express Flash PM1725b NVMe (2.9T each, ~6TB total LVM)
  - System: SSD (ROTA=0)
  - Disk performance: 3.4 GB/s write (dd test)

### Software
- **OS**: Red Hat Enterprise Linux release 9.6 (Plow)
- **Kernel**: 5.14.0-570.12.1.el9_6.x86_64
- **Virtualization**:
  - QEMU: 9.1.0 (qemu-kvm-9.1.0-15.el9)
  - libvirt: 10.10.0
  
### Memory Configuration
- **Hugepages**: 
  - Transparent hugepages: [always] madvise never (ENABLED)
  - AnonHugePages: 172,212,224 kB (~168 GB)
  - HugePages_Total: 0 (not using static hugepages)
  
- **KSM (Kernel Samepage Merging)**: Disabled (0)

### System Configuration
- **SELinux**: Permissive
- **cgroup**: cgroup v2
- **NUMA**: Present (numactl available, but output truncated)

---

## OFCIR Machine (FAILING)

### Hardware
- **CPU**: Unknown (not captured in logs)
  - Need to verify: likely different Intel/AMD model than Beaker
  
- **Memory**: 188 GB total RAM (192,528 MB)
  - Initial state: 2.3 GB used, 186 GB free
  - Swap: 67 GB created dynamically (69,616 MB swapfile)
  - Swappiness: Unknown (not captured)
  - **CRITICAL**: Much less RAM than Beaker (188 GB vs 376 GB)

- **Disk**: 
  - System disk: Single NVMe drive (nvme0n1, 1TB)
  - Partition layout:
    - /dev/nvme0n1p4: 1022.9G (root filesystem, XFS)
    - /dev/nvme0n1p3: 1000M (boot, XFS)
    - /dev/nvme0n1p2: 100M (EFI, vfat)
  - Disk performance: Not measured in logs
  - **CRITICAL**: Single NVMe vs dual NVMe RAID on Beaker

### Software
- **OS**: Rocky Linux 9 (based on package repos)
  - Rocky Linux 9 - BaseOS
  - Rocky Linux 9 - AppStream
  - Rocky Linux 9 - Extras
  
- **Kernel**: Unknown (not captured in logs)
  
- **Virtualization**:
  - QEMU: 17:9.1.0-29.el9_7.6 (qemu-kvm package)
  - libvirt: 10.10.0-15.9.el9_7
  - **Same major versions as Beaker**

### Memory Configuration
- **Hugepages**: Unknown (not captured)
- **KSM**: Unknown (not captured)

### System Configuration
- **SELinux**: Unknown (not captured)
- **cgroup**: Unknown (not captured)
- **NUMA**: Unknown (not captured)

---

## Key Differences

### CRITICAL Differences (Likely Impact)

1. **Total RAM**:
   - Beaker: 376 GB
   - OFCIR: 188 GB (50% less)
   - **Impact**: Golden image creation is memory-intensive. Less RAM means more swapping, slower VM provisioning, potential OOM.

2. **Disk Configuration**:
   - Beaker: Dual NVMe in RAID + dedicated data LVM (6TB)
   - OFCIR: Single 1TB NVMe
   - **Impact**: Lower I/O throughput, no redundancy, slower disk operations during VM creation.

3. **Swap Setup**:
   - Beaker: 4 GB static swap partition
   - OFCIR: 67 GB dynamic swapfile created at runtime
   - **Impact**: Large swapfile suggests memory pressure. Swapfile on same disk as root FS competes for I/O.

4. **CPU**:
   - Beaker: 80 vCPUs (Intel Xeon Gold 5218R, 2.1-4.0 GHz)
   - OFCIR: Unknown
   - **Impact**: Unknown, but likely fewer vCPUs on EC2 instance.

5. **Transparent Hugepages**:
   - Beaker: ENABLED ([always])
   - OFCIR: Unknown
   - **Impact**: THP improves memory performance for KVM. If disabled on OFCIR, VMs may have worse memory performance.

### Differences (Uncertain Impact)

6. **OS Distribution**:
   - Beaker: RHEL 9.6
   - OFCIR: Rocky Linux 9
   - **Impact**: Minor. Rocky is RHEL-compatible, but could have subtle differences.

7. **SELinux Mode**:
   - Beaker: Permissive
   - OFCIR: Unknown (likely Enforcing by default)
   - **Impact**: If Enforcing, could block certain operations.

8. **Network Setup**:
   - Beaker: Complex (many bridge/veth interfaces for existing VMs)
   - OFCIR: Clean setup (fresh machine)
   - **Impact**: Unlikely.

---

## Missing Data for OFCIR

The following information was NOT captured in the CI logs and should be collected:

1. **CPU details**: `lscpu` output
2. **Kernel version**: `uname -r`
3. **Hugepages config**: `cat /proc/meminfo | grep -i huge`
4. **Transparent hugepages**: `cat /sys/kernel/mm/transparent_hugepage/enabled`
5. **KSM status**: `cat /sys/kernel/mm/ksm/run`
6. **Swappiness**: `cat /proc/sys/vm/swappiness`
7. **SELinux mode**: `getenforce`
8. **NUMA topology**: `numactl --hardware`
9. **Disk I/O performance**: `dd if=/dev/zero of=/tmp/disktest bs=1M count=256 oflag=direct`
10. **QEMU/KVM feature flags**: `qemu-system-x86_64 -cpu help` or `virsh capabilities`

---

## Recommendations

### Immediate Actions

1. **Collect missing system info from OFCIR**:
   - Add a diagnostic step to the ofcir-setup workflow to capture CPU, kernel, hugepages, etc.
   - Log output to build-log.txt for future analysis.

2. **Verify memory requirements**:
   - Calculate actual memory needed for golden image creation (VMs + overhead).
   - If >188 GB, this explains the failures. Request larger EC2 instance types.

3. **Compare VM memory stats**:
   - Look at `virsh dommemstat` output during golden-setup in both passing and failing runs.
   - Check for differences in RSS (resident set size), swap usage, or available memory.

### Hypotheses to Test

1. **Memory pressure hypothesis**:
   - OFCIR has half the RAM of Beaker.
   - Golden image creation spawns multiple VMs simultaneously.
   - OFCIR runs out of memory, causing VMs to be slow, unresponsive, or OOM-killed.
   - **Test**: Monitor memory during golden-setup. Check for OOM events in dmesg.

2. **Disk I/O hypothesis**:
   - OFCIR has slower disk I/O than Beaker (single NVMe vs RAID).
   - VM disk image operations (qcow2 creation, snapshotting, backing file chains) are slower.
   - **Test**: Measure disk I/O during golden-setup. Compare with Beaker.

3. **Transparent hugepages hypothesis**:
   - Beaker has THP enabled, OFCIR may not.
   - VMs have worse memory performance on OFCIR.
   - **Test**: Check THP status on OFCIR. Enable and retest.

4. **Swapfile placement hypothesis**:
   - OFCIR's 67 GB swapfile is on the same disk as root FS.
   - Heavy swapping during VM creation causes disk I/O contention.
   - **Test**: Check swap usage during golden-setup. If >10%, memory is the bottleneck.

---

## Next Steps

1. SSH into an OFCIR machine during a CI run and collect the missing system info.
2. Compare the full system profile with Beaker.
3. Analyze `virsh dommemstat` output from both passing and failing runs.
4. If memory is the issue, request larger EC2 instance types or reduce VM concurrency.
5. If disk I/O is the issue, optimize qcow2 operations or use faster storage.

