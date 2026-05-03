# PR 78362 - Failed CI Job Analysis

## Summary

3 different jobs failed with 3 DIFFERENT failure modes. This is NOT the "Unauthenticated" error seen previously. Each failure is a distinct issue.

## Job 1: e2e-metal-vmaas-compute-instance-creation-golden

**Test:** `tests/vmaas/test_compute_instance_creation.py::test_compute_instance_lifecycle`
**Duration:** 194.01s (3m 14s)
**Setup:** PASSED
**Test:** FAILED

### Error
```
subprocess.CalledProcessError: Command '('grpcurl', '-d', '{"token": "eyJ...JWT..."}', 
'fulfillment-api-osac-e2e-ci.apps.test-infra-cluster-d55276d8.redhat.com:443', 
'osac.public.v1.ComputeInstances/List')' returned non-zero exit status 80.
```

### Failure Mode
The test is calling `grpcurl` to invoke the `ComputeInstances/List` gRPC method. The command returns exit code 80, which is a grpcurl-specific error code.

**Exit code 80** in grpcurl typically means:
- Unable to parse response
- Response proto decode failure
- Connection issue after successful TLS handshake

This is NOT an authentication error (that would be exit code 16). The JWT token is being accepted, but the gRPC call itself is failing at the protocol level.

### Exact Failure Point
The test lifecycle is:
1. Create compute instance (appears to work - no error shown)
2. List compute instances (FAILS HERE with exit 80)
3. Would proceed to delete, post-delete list, etc.

The test fails on the FIRST List call after creation.

---

## Job 2: e2e-metal-vmaas-compute-instance-restart-golden

**Test:** `tests/vmaas/test_compute_instance_restart.py::test_compute_instance_restart`
**Duration:** 915.63s (15m 15s)
**Setup:** PASSED
**Test:** FAILED

### Error
```python
TimeoutError: vm-np6mj Running — timeout after 900s, last value: 'Starting'
```

### Failure Mode
The test successfully creates a compute instance (CR name: `vm-np6mj`), but the VM never transitions from `Starting` to `Running` state.

The test polls for 900 seconds (15 minutes) waiting for the VM to reach `Running`, but it remains stuck in `Starting` state.

### Test Flow
```python
uuid: str = cli.create_compute_instance(template=vm_template)  # SUCCESS
ci_name: str = wait_for_cr(k8s=k8s_hub_client, uuid=uuid)      # SUCCESS (got 'vm-np6mj')
wait_for_running(k8s=k8s_hub_client, name=ci_name)             # TIMEOUT - stuck at 'Starting'
```

### Exact Failure Point
The VM creation request is accepted and a ComputeInstance CR is created, but the underlying fulfillment process never transitions the VM to Running. This suggests:
- The fulfillment controller is processing the request
- The VM is being created on the virt cluster
- But the VM itself is not starting successfully (stuck in Starting state)

This is a VM provisioning failure, not an API or authentication issue.

---

## Job 3: e2e-metal-vmaas-compute-instance-restart-negative-golden

**Test:** `tests/vmaas/test_compute_instance_restart_negative.py::test_compute_instance_restart_past_timestamp_ignored`
**Duration:** 203.78s (3m 23s)
**Setup:** PASSED
**Test:** FAILED

### Error
```python
subprocess.CalledProcessError: Command '('kubectl', '--as', 'system:admin', 'get', 
'computeinstance', 'vm-zvwvx', '-n', 'osac-e2e-ci', '-o', 
'jsonpath={.status.lastRestartedAt}')' returned non-zero exit status 1.
```

### Failure Mode
The test is trying to read the `status.lastRestartedAt` field from a ComputeInstance CR named `vm-zvwvx`.

Exit code 1 from kubectl with jsonpath typically means:
- The field doesn't exist (not found in the status)
- The CR doesn't exist (but the error would be different)
- The field path is incorrect

### Exact Failure Point
The test is expecting the ComputeInstance CR to have a `.status.lastRestartedAt` field populated, but:
- Either the field doesn't exist in the CR status
- Or the CR was deleted/not created
- Or the controller is not populating this field

This is a test assumption failure - the test expects a field that is not present in the actual CR.

---

## Key Observations

### 1. All Setup Steps Pass
All 3 jobs have their setup phase succeed. This means:
- The hub cluster is healthy
- The virt cluster is healthy
- Authorino is deployed
- The fulfillment controller is deployed
- Networking/firewall rules are configured
- Cross-cluster connectivity works

### 2. Different Failure Modes
- **Job 1:** gRPC protocol error (exit 80) on List call
- **Job 2:** VM provisioning timeout (stuck in Starting)
- **Job 3:** Missing CR status field (lastRestartedAt)

### 3. No Authentication Errors
None of these are the "Unauthenticated: permission denied" error seen in previous runs. The JWT tokens are being accepted.

### 4. Non-Deterministic Failures
These 3 jobs failed this time, but 5 other jobs passed. The previous run had 4 different jobs fail. This suggests:
- Race conditions
- Resource contention
- Timing-dependent issues
- Infrastructure instability

---

## Critical Questions to Answer

### For Job 1 (grpcurl exit 80):
1. What does the fulfillment-api service log show for this request?
2. Is the response malformed?
3. Is there a proto mismatch between client and server?
4. Does the List method implementation have a bug that causes proto encoding errors?

### For Job 2 (VM stuck Starting):
1. What does the fulfillment controller log show for vm-np6mj?
2. What is the actual state of the VirtualMachine on the virt cluster?
3. Are there resource constraints (CPU, memory, storage)?
4. Is there a kubevirt issue preventing the VM from booting?

### For Job 3 (missing status field):
1. Is `.status.lastRestartedAt` expected to exist after a restart request?
2. Does the controller populate this field?
3. Is the field name correct?
4. Was the restart request actually processed?

---

## Root Cause Hypothesis

### Job 1: gRPC Protocol Error
The grpcurl exit code 80 suggests one of:
1. **Proto schema mismatch**: The List response proto definition changed but the test client wasn't updated
2. **Malformed response**: The fulfillment-api is returning data that doesn't match the proto schema
3. **Envoy/grpcurl version issue**: The grpcurl binary or proto files in the test image are stale

**Most Likely:** The List method is returning a response that violates the proto schema. This could happen if:
- A new field was added to the response but marked as required instead of optional
- The response includes invalid UTF-8 in a string field
- There's a nil pointer in the response that should be omitted or have a default value

### Job 2: VM Provisioning Failure
The VM gets stuck in `Starting` state for 15 minutes. This is NOT an API issue - the create request succeeded. Possible causes:
1. **Resource exhaustion**: The virt cluster can't schedule the VM (no available nodes, insufficient CPU/mem)
2. **Image pull failure**: The VM image is corrupted or unreachable
3. **Storage provisioning failure**: The PVC for the VM disk is pending
4. **Kubevirt bug**: The VirtualMachine controller is stuck/crashed

**Most Likely:** This is a golden image-specific issue. The VM template references the golden image, and either:
- The image path is wrong
- The image is corrupted
- The image is too large and provisioning times out

### Job 3: Missing Status Field
The test expects `.status.lastRestartedAt` but kubectl can't find it. Either:
1. **Field not implemented**: The controller doesn't populate this field yet
2. **Field name changed**: The field was renamed in the CRD but test wasn't updated
3. **Test timing issue**: The test checks before the controller updates the status

**Most Likely:** This is a test vs. implementation mismatch. The test was written expecting a feature (lastRestartedAt tracking) that either:
- Hasn't been implemented yet
- Was implemented differently (different field name)
- Only gets populated under certain conditions

---

## Comparison with Previous Failures

### Previous Run (4 failures)
The previous run had "Unauthenticated: permission denied" errors, which we hypothesized were due to:
- Authorino not ready
- Token validation failing
- RBAC misconfiguration

### This Run (3 failures, different jobs)
This run has completely different errors:
- gRPC protocol errors
- VM provisioning timeouts
- Missing CR fields

### Pattern: Flakiness
The fact that:
- 5/8 jobs pass consistently
- 3/8 jobs fail with rotating errors
- Different jobs fail each run

Suggests the root cause is NOT in the core functionality, but in:
- **Test infrastructure instability**
- **Race conditions in setup**
- **Resource contention between parallel jobs**
- **Golden image quality issues**

---

## Actionable Recommendations

### Immediate Actions

1. **Re-run the rehearsal jobs** - If the 3 failed jobs pass on retry, this confirms infrastructure flakiness
2. **Check golden image integrity** - Validate the QCOW2 image wasn't corrupted during upload/reassembly
3. **Review proto definitions** - Ensure the List response proto matches what the test expects
4. **Check CRD status schema** - Verify if `lastRestartedAt` exists in the ComputeInstance CRD

### Long-term Fixes

1. **Add retries to tests** - Make tests resilient to transient infrastructure issues
2. **Improve test isolation** - Ensure jobs don't compete for resources
3. **Add better error messages** - When grpcurl exits with 80, capture and log the actual error
4. **Implement missing features** - If `lastRestartedAt` is expected, implement it or update the test
5. **Golden image CI validation** - Before uploading to GCS, validate the image boots successfully

---

## Data Needed for Root Cause Confirmation

Cannot extract from available artifacts (logs are too large/binary):
1. Fulfillment-api pod logs during Job 1's List call
2. Fulfillment controller logs during Job 2's VM creation
3. ComputeInstance CR YAML for vm-zvwvx from Job 3
4. VirtualMachine resource status for vm-np6mj on the virt cluster

These would require accessing the live cluster during test execution or having structured log extraction in the gather phase.
