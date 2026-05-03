# Hub VM Resource Configuration Investigation

**Investigation Date:** 2026-04-29
**VM Examined:** test-infra-cluster-d55276d8-master-0 on rdu-infra-edge-07.infra-edge.lab.eng.rdu2.redhat.com

## Critical Finding: No Disk Cache Configuration

**PROBLEM:** The disk driver configuration has NO explicit cache mode set:
```xml
<driver name='qemu' type='qcow2'/>
```

When no cache mode is specified, QEMU uses the **default cache mode**, which varies by disk type:
- For file-backed disks (like these qcow2 images): default is `cache=writethrough`
- This means: reads are cached, writes go directly through to disk

**Impact on EBS storage:**
- EBS has high latency compared to local NVMe (milliseconds vs microseconds)
- Every etcd write, every API server write hits EBS directly with no buffering
- On systems with local NVMe, this latency is masked; on EBS, it becomes visible
- This explains why the same VM works on local storage but fails on EBS

**Recommendation:** Add explicit cache configuration optimized for EBS:
```xml
<driver name='qemu' type='qcow2' cache='writeback' io='native'/>
```
- `cache=writeback`: writes are buffered in memory, reducing latency
- `io=native`: use Linux native AIO for better performance

## VM Resource Configuration

### Memory Configuration
```xml
<memory unit='KiB'>67108864</memory>         <!-- 64 GB -->
<currentMemory unit='KiB'>67108864</currentMemory>
```

**Memory balloon status:**
```
actual       67108864  (64 GB - allocated)
unused       65504592  (62.5 GB - guest reports as unused)
available    65841108  (62.8 GB - available to guest)
usable       65089280  (62.1 GB - usable by guest)
rss          50952400  (48.6 GB - actually resident on host)
```

**Analysis:**
- VM has full 64 GB allocated (no deflation by host)
- Only 48.6 GB is actually resident (rest is swapped or not yet touched)
- 62.5 GB reported unused by guest - plenty of free memory
- **No memory pressure detected**

### Memory Balloon Configuration
```xml
<memballoon model='virtio'>
  <address type='pci' domain='0x0000' bus='0x00' slot='0x0a' function='0x0'/>
</memballoon>
```

**Analysis:**
- Memory balloon driver is enabled (virtio-balloon)
- This ALLOWS the host to reclaim memory from the VM
- However, `actual` == `memory`, so no deflation has occurred
- **Memory balloon is not causing the issue**

### CPU Configuration
```xml
<vcpu placement='static'>16</vcpu>
<cpu mode='host-passthrough' check='none' migratable='on'/>
```

**Analysis:**
- 16 vCPUs allocated
- Host CPU passthrough (no CPU limits/throttling)
- **No CPU constraints detected**

### Disk Configuration

**OS disk (sda):**
```xml
<disk type='file' device='disk'>
  <driver name='qemu' type='qcow2'/>
  <source file='/data/golden-debug/hub/hub-os.qcow2' index='2'/>
  <target dev='sda' bus='scsi'/>
  <wwn>05abcdc54d18e525</wwn>
</disk>
```

**Data disk (vdb):**
```xml
<disk type='file' device='disk'>
  <driver name='qemu' type='qcow2'/>
  <source file='/data/golden-debug/hub/hub-data.qcow2' index='1'/>
  <target dev='vdb' bus='virtio'/>
</disk>
```

**Missing configuration:**
- No `cache=` attribute (defaults to `writethrough`)
- No `io=` attribute (defaults to `threads`, not `native`)
- No `discard=` attribute (no TRIM/discard support)

**Impact:**
- Every write goes directly to underlying storage (EBS in CI)
- No write buffering to mask EBS latency
- Thread-based IO instead of native AIO (less efficient)

## Resource Limits: NONE FOUND

**No memtune limits:**
```bash
$ grep -i memtune hub-domain-fixed.xml
# (no output - no memory tuning configured)
```

**No cputune limits:**
```bash
$ grep -i cputune hub-domain-fixed.xml
# (no output - no CPU tuning configured)
```

**No blkiotune limits:**
```bash
$ grep -i blkiotune hub-domain-fixed.xml
# (no output - no block IO tuning configured)
```

**No hugepages:**
```bash
$ grep -i hugepage hub-domain-fixed.xml
# (no output - using normal pages)
```

## Root Cause Analysis

The kube-apiserver crashes are **NOT** caused by VM resource limits. The VM has:
- 64 GB memory fully allocated with no deflation
- 16 vCPUs with host passthrough
- No memory, CPU, or disk IO throttling

**The root cause is disk IO latency:**

1. **Default cache mode = writethrough**: every write hits storage directly
2. **EBS high latency**: milliseconds vs microseconds for local NVMe
3. **etcd sensitivity**: etcd requires low-latency storage; high write latency causes warnings/errors
4. **kube-apiserver dependency**: API server depends on etcd; slow etcd = slow/failing API server

## Recommended Fix

Update the disk configuration in the golden image domain XML:

```xml
<disk type='file' device='disk'>
  <driver name='qemu' type='qcow2' cache='writeback' io='native' discard='unmap'/>
  <source file='/data/golden-debug/hub/hub-os.qcow2'/>
  <target dev='sda' bus='scsi'/>
</disk>

<disk type='file' device='disk'>
  <driver name='qemu' type='qcow2' cache='writeback' io='native' discard='unmap'/>
  <source file='/data/golden-debug/hub/hub-data.qcow2'/>
  <target dev='vdb' bus='virtio'/>
</disk>
```

**Changes:**
- `cache='writeback'`: buffer writes in memory to mask EBS latency
- `io='native'`: use Linux native AIO for better performance
- `discard='unmap'`: enable TRIM/discard for better space management

**Risk mitigation:**
- `writeback` cache introduces data loss risk if host crashes before flushing
- For CI environment (ephemeral VMs), this is acceptable
- For production, consider `cache='none'` with faster storage backend

## Files Examined
- Running VM config: `virsh dumpxml test-infra-cluster-d55276d8-master-0`
- Golden image config: `/data/golden-debug/hub/hub-domain-fixed.xml`
- Memory stats: `virsh dommemstat test-infra-cluster-d55276d8-master-0`
