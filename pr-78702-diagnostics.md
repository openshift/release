# PR 78702 Failed Job Diagnostics

All jobs from PR 78702 on openshift/release.

## Machine Configuration

All jobs ran on machines with:
- **Total Memory**: 192528 MB (188 GB)
- **Swap**: 0 MB initially, 69616 MB allocated during setup
- Final memory at failure: 188 GB total, ~66 GB used, ~121 GB available, 67 GB swap (9 MB used)

---

## Job 1: ci-delete-during-provision-golden
**Run**: 2050270307628879872

### Test Log Status
**CENSORED** - "This file contained potentially sensitive information and has been removed."

No pytest error or diagnostics available.

---

## Job 2: compute-instance-creation-golden
**Run**: 2050270307826012160

### Test Log Status
**CENSORED** - "This file contained potentially sensitive information and has been removed."

No pytest error or diagnostics available.

---

## Job 3: compute-instance-restart-golden
**Run**: 2050270307876343808

### Pytest Error
```
FAILED tests/vmaas/test_compute_instance_restart.py::test_compute_instance_restart

subprocess.CalledProcessError: Command '('kubectl', '--as', 'system:admin', 'get', 'computeinstance', 'vm-55qb4', '-n', 'osac-e2e-ci', '-o', 'jsonpath={.status.lastRestartedAt}')' returned non-zero exit status 1.
```

**Error Context:**
- Test was waiting for restart to complete after calling \`grpc.update_restart()\`
- Trying to query Hub API for ComputeInstance status
- Hub API was unreachable at time of failure

**Full Traceback:**
The test successfully:
1. Created a compute instance
2. Waited for CR to appear
3. Waited for it to reach running state
4. Got the VMI namespace
5. Got original VMI creation timestamp
6. Got initial lastRestartedAt value
7. Called grpc.update_restart()

Then FAILED when trying to poll for restart completion - Hub API was down.

### POST-FAILURE DIAGNOSTICS

```
18:59:43 ========== POST-FAILURE DIAGNOSTICS ==========
--- Host memory ---
               total        used        free      shared  buff/cache   available
Mem:           188Gi        66Gi       783Mi       2.0Mi       121Gi       121Gi
Swap:           67Gi       9.0Mi        67Gi

--- Hub API reachable? ---
HUB API UNREACHABLE

--- Virt API reachable? ---
ok

--- OSAC pods ---
E0501 18:59:43.708042   35597 memcache.go:265] "Unhandled Error" err="couldn't get current server API group list: Get \"https://api.test-infra-cluster-d55276d8.redhat.com:6443/api?timeout=32s\": dial tcp 192.168.131.10:6443: connect: connection refused"
[...repeated connection refused errors...]
The connection to the server api.test-infra-cluster-d55276d8.redhat.com:6443 was refused - did you specify the right host or port?

--- OSAC deployments ---
[Same connection refused errors - cannot reach Hub API]

--- Recent events ---
[Same connection refused errors - cannot reach Hub API]

--- OSAC operator logs (last 50) ---
[Same connection refused errors - cannot reach Hub API]

--- Fulfillment controller logs (last 30) ---
[Same connection refused errors - cannot reach Hub API]

--- Fulfillment gRPC server logs (last 30) ---
[Same connection refused errors - cannot reach Hub API]

--- Authorino logs (last 30) ---
[Same connection refused errors - cannot reach Hub API]

--- Host dmesg (OOM) ---
no OOM

--- VM status ---
 Id   Name                                   State
------------------------------------------------------
 1    test-infra-cluster-d55276d8-master-0   running
 2    test-infra-cluster-ad07fc71-master-0   running

18:59:44 ========== END DIAGNOSTICS ==========
```

**Key Findings:**
- Hub API completely unreachable (connection refused to 192.168.131.10:6443)
- Virt API was still reachable
- No OOM kills detected
- Both VMs (hub and virt masters) still running according to virsh
- Could not retrieve logs from any Hub cluster pods/deployments due to API failure
- Host memory: 188 GB total, 66 GB used, 121 GB available - plenty of memory
- Swap: 67 GB allocated, only 9 MB used

**Root Cause:** Hub cluster API server completely crashed/stopped responding. Not a memory issue.

---

## Job 4: subnet-lifecycle-golden
**Run**: 2050270307993784320

### Test Log Status
**CENSORED** - "This file contained potentially sensitive information and has been removed."

No pytest error or diagnostics available.

---

## Summary

- **Jobs 1, 2, 4**: Test logs censored - cannot retrieve diagnostics
- **Job 3**: Full diagnostics available showing Hub API crash
- **Common Configuration**: All jobs used 188 GB machines with 67 GB swap
- **Job 3 Failure Mode**: Hub cluster complete API failure (connection refused), not resource exhaustion
- **Memory**: Plenty available (121 GB free) - NOT a memory issue
- **Next Steps**: Need to check setup logs for all jobs to see if Hub API was ever reachable, and check for patterns in VM/cluster creation
