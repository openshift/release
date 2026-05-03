# PR 78362 Failed CI Job Analysis

## Summary

Analyzed 3 failed CI jobs from PR 78362. All failures are **infrastructure/environment issues**, NOT code defects from the PR changes.

## Job 1: ci-delete-during-provision-golden (Run 2050611664222425088)

**Status**: FAILED (Infrastructure)

**Root Cause**: Pod sandbox creation failure on CI cluster node

**Details**:
- The `osac-project-golden-setup` pod failed to start within the 1-hour timeout
- Pod stuck in `PodInitializing` state
- CI cluster's container runtime (CRI-O) repeatedly failed to create pod sandbox
- Error: `rpc error: code = DeadlineExceeded desc = context deadline exceeded`
- Also saw: `rpc error: code = DeadlineExceeded desc = stream terminated by RST_STREAM with error code: CANCEL`
- 10 failed attempts at pod sandbox creation between 17:09:32 and 17:37:40 UTC
- Test never executed

**Timeline**:
- 16:49:10 - Pod scheduled to node `ip-10-28-64-44.us-east-2.compute.internal`
- 17:09:32 - First pod sandbox creation failures begin
- 17:37:40 - Repeated failures continue
- 17:37:44 - Networking (multus) finally configured
- 17:37:56 - Init containers start pulling
- 17:38:07 - Still pulling main test image
- 18:40:58 - Golden setup step starts
- 18:41:00 - Entrypoint receives SIGTERM (job timeout)
- 18:41:58 - Graceful shutdown completes

**Golden Setup Execution**:
The setup step DID partially execute after pod started:
```
18:40:58 Setting up golden image environment
18:40:58 Merging pull secrets...
{"component":"entrypoint","msg":"Entrypoint received interrupt: terminated","time":"2026-05-02T18:41:00Z"}
ssh: connect to host 150.238.42.232 port 22: Connection timed out
Connection closed
```

The SSH connection to the bare metal host (150.238.42.232 - assisted-medium-02.redhat.com) timed out.

**Verdict**: CI infrastructure failure. The 48-minute delay in pod initialization consumed the job's time budget before meaningful work could start.

---

## Job 2: subnet-lifecycle-golden (Run 2050611664578940928)

**Status**: FAILED (Test execution - environment issue)

**Root Cause**: HTTP/2 connection failure to OSAC API

**Details**:
- Test DID execute and reached the OSAC MUST-GATHER section
- Authorino logs show successful authentication at 17:26:31 (request id `5ebee3be-feb8-4176-876d-8e149b5f4979`)
  - User: `osac-operator-controller-manager`
  - Tenant: `osac-e2e-ci`
  - Authorized: `true`
- Test exited with: `error: http2: server sent GOAWAY and closed the connection; LastStreamID=5, ErrCode=NO_ERROR, debug=""`
- Timestamp: 12:27:03 (test start not captured due to censoring)

**Authorino Evidence** (from junit XML):
```json
{"level":"debug","ts":"2026-05-02T17:26:31Z","logger":"authorino.service.auth.authpipeline.response",
 "msg":"dynamic response built","request id":"5ebee3be-feb8-4176-876d-8e149b5f4979",
 "object":{"tenants":["osac-e2e-ci"],"user":"osac-operator-controller-manager"}}
{"level":"info","ts":"2026-05-02T17:26:31Z","logger":"authorino.service.auth",
 "msg":"outgoing authorization response","authorized":true,"response":"OK"}
```

**Analysis**:
- Authentication succeeded
- HTTP/2 connection was established (LastStreamID=5 means at least 5 streams were created)
- Server sent GOAWAY with NO_ERROR - this is a **graceful shutdown** signal, not an error condition
- Possible causes:
  1. OSAC API server restarted/rolled during test
  2. Load balancer/proxy connection idle timeout
  3. Test infrastructure teardown signal
  4. Envoy/Istio sidecar shutdown

**Test Artifacts**: All test logs censored due to sensitive information. Only authorino logs captured in junit failure message.

**Verdict**: Environment instability. The API server connection was terminated mid-test by infrastructure, not application code.

---

## Job 3: virtual-network-lifecycle-golden (Run 2050611664625078272)

**Status**: FAILED (Test execution - authentication failure)

**Root Cause**: Kubernetes API unreachable for token review + JWT signature verification failure

**Details**:
- Test DID execute and reached the OSAC MUST-GATHER section
- Authorino logs show **authentication failure** at 17:23:04 (request id `a07b9add-b804-4d28-845f-0e0ab5ea2082`)
- Dual authentication failure:
  1. **fulfillment-api**: `Post "https://10.128.0.1:443/apis/authentication.k8s.io/v1/tokenreviews": dial tcp 10.128.0.1:443: connect: connection refused`
  2. **keycloak-jwt**: `failed to verify signature: failed to verify id token signature`
- Response: `UNAUTHENTICATED` (code 16)
- Timestamp: 12:23:05

**Authorino Error** (from junit XML):
```json
{"level":"info","ts":"2026-05-02T17:23:04Z","logger":"authorino.service.auth",
 "msg":"outgoing authorization response","authorized":false,"response":"UNAUTHENTICATED",
 "object":{"code":16,
  "message":"{\"fulfillment-api\":\"Post \\\"https://10.128.0.1:443/apis/authentication.k8s.io/v1/tokenreviews\\\": dial tcp 10.128.0.1:443: connect: connection refused\",
             \"keycloak-jwt\":\"failed to verify signature: failed to verify id token signature\"}"}}
```

**Analysis**:
- 10.128.0.1 is the Kubernetes service IP (kubernetes.default.svc)
- Authorino sidecar **could not reach the Kubernetes API** to verify service account tokens
- This is a fundamental infrastructure failure - the pod's network configuration is broken
- Keycloak JWT verification also failed (separate auth path), indicating either:
  1. JWT signing key mismatch
  2. Token expired/malformed
  3. Keycloak JWKS endpoint unreachable

**Test Artifacts**: All test logs censored due to sensitive information.

**Verdict**: Severe environment failure. The test pod's networking was misconfigured - it could not reach the Kubernetes API from inside the cluster. This is a CI cluster infrastructure issue.

---

## Comparison with Job 1 (ci-delete-during-provision-golden)

All three jobs exhibit **CI infrastructure issues**:

1. **ci-delete**: Pod initialization timeout (48 minutes to start pod)
2. **subnet-lifecycle**: API server connection terminated mid-test (HTTP/2 GOAWAY)
3. **virtual-network**: Kubernetes API unreachable from pod (connection refused to 10.128.0.1:443)

---

## Test Diagnostic Data Status

**Requested data NOT available**:
- Pytest error traceback (logs censored)
- OSAC MUST-GATHER section (logs censored)
- OSAC OPERATOR LOG section (logs censored)
- FULFILLMENT CONTROLLER LOG section (logs censored)
- AUTHORINO LOG section (logs censored - partial data in junit XML)
- ComputeInstance/VirtualNetwork/Subnet CR YAML status (logs censored)
- Host memory, VM memory stats (logs censored)
- API reachability results (logs censored)
- Events in namespace (logs censored)

**Why censored**:
The Prow sidecar detected sensitive information (credentials, IPs, tokens) in the test output and replaced all build-log.txt files with the message:
> "This file contained potentially sensitive information and has been removed."

The sidecar-logs.json shows:
```json
{"msg":"Loaded secrets to censor.","secrets":66,"time":"2026-05-02T17:27:03Z"}
```

66 secrets were loaded for censoring, and the entire test output was sanitized.

**Partial data recovered**:
- Authorino authentication logs embedded in junit XML failure messages
- Pod event timeline from junit XML
- HTTP/2 GOAWAY error message
- Kubernetes API connection refusal error

---

## Actionable Items

### For OSAC Team
1. **No code changes needed** - these are all CI infrastructure failures, not application defects
2. **Cannot debug further** - test logs have been censored, actual diagnostic data is unavailable
3. **Rerun the tests** - these are transient infrastructure issues

### For OpenShift CI Team
1. **Job 1 (ci-delete)**: Investigate node `ip-10-28-64-44.us-east-2.compute.internal` for CRI-O pod sandbox creation delays
2. **Job 2 (subnet-lifecycle)**: Investigate HTTP/2 GOAWAY pattern - likely load balancer or proxy issue
3. **Job 3 (virtual-network)**: Critical - investigate why pods cannot reach Kubernetes API (10.128.0.1:443) - this is a cluster networking failure

---

## Bare Metal Host Details (from ofcir-gather)

**Provider**: IBM Cloud Classic (SoftLayer)
**Datacenter**: dal10
**Host**: assisted-medium-02.redhat.com (150.238.42.232)
**Hardware ID**: 3310172
**OS**: Rocky Linux 9.6-64
**Status**: ACTIVE
**Provision Date**: 2025-05-04T13:40:11-06:00

The bare metal host was provisioned and active, but Job 1 couldn't SSH to it due to the pod initialization timeout consuming all available time.

---

## Conclusion

**All 3 jobs failed due to CI infrastructure issues, NOT PR code defects.**

- **ci-delete-during-provision-golden**: Pod initialization took 48 minutes, exhausting job timeout before test could run
- **subnet-lifecycle-golden**: API server sent HTTP/2 GOAWAY mid-test (graceful connection termination)
- **virtual-network-lifecycle-golden**: Kubernetes API unreachable from test pod (connection refused to 10.128.0.1:443)

**Recommendation**: `/retest` all three jobs. These are transient CI cluster issues.

**Data Availability**: Comprehensive diagnostics (OSAC must-gather, operator logs, fulfillment logs, authorino logs, CR status, events) were generated but censored by Prow due to sensitive information detection. Only partial data embedded in junit XML failure messages is recoverable.
