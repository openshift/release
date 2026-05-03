# Certificate Rotation Investigation - Hub kube-apiserver Intermittent Downtime

## Executive Summary

Investigated the theory that OpenShift certificate rotation causes intermittent kube-apiserver downtime when booting from aged golden QCOW2 images. The investigation CONFIRMS that certificate rotation triggers kube-apiserver restarts, but timing analysis shows the specific test failures analyzed were NOT caused by this mechanism.

## Key Findings

### 1. Certificate Rotation Evidence - CONFIRMED

The hub cluster shows clear evidence of automatic certificate rotation:

**Operator Logs** (`/tmp/review-release-78362/logs/pr78699`):
```
I0502 22:16:09.346744 certrotationcontroller.go:148 Setting monthPeriod to 720h0m0s, yearPeriod to 8760h0m0s
I0502 22:16:09.762295 Event: SignerUpdateRequired "aggregator-client-signer" in "openshift-kube-apiserver-operator" requires a new signing cert/key pair: past its refresh time 2026-04-29 13:43:53 +0000 UTC
```

**Certificate Creation**:
```
NAME                                       AGE
localhost-recovery-serving-certkey-10      8h
```

The certificate `localhost-recovery-serving-certkey-10` was created 8 hours before inspection, exactly matching the kube-apiserver pod restart time.

**Pod Restart Evidence**:
```
NAME                                                  READY   STATUS      RESTARTS   AGE
installer-10-test-infra-cluster-d55276d8-master-0     0/1     Completed   0          8h
kube-apiserver-test-infra-cluster-d55276d8-master-0   5/5     Running     0          7h59m
```

The `kube-apiserver` pod shows AGE of 7h59m, and the installer-10 pod (which deploys revision 10) completed 8h ago.

**Revision Rollout**:
The cluster is currently at revision 10 (`latestAvailableRevision: 10`). Revisions 1-9 are older (18-19 days), while revision 10 is only 8 hours old.

### 2. Timeline Analysis

**Test Run Timeline (May 2, 2026)**:
- 17:26:31 - Test begins, Authorino shows authentication success
- 17:27:03 - Tests FAIL (subnet-lifecycle, virtual-network-lifecycle)
- 22:16:09 - kube-apiserver-operator detects expired signing cert
- 22:17:02 - installer-10 pod starts to deploy new revision
- 22:17:32 - Revision 10 installer completes
- ~22:20 - kube-apiserver pod restarts with new certificates

**Golden Image Timeline**:
- April 13 - Cluster originally created (19 days before inspection)
- April 29 13:43:53 UTC - Certificate refresh deadline passed
- May 1 18:47 - OLD golden image setup completed for testing
- May 2 17:27 - Tests FAIL (5 hours before cert rotation)
- May 2 22:07 - NEW golden image QCOW2 files created
- May 2 22:17 - Certificate rotation triggered, kube-apiserver restarts

**Critical Gap**: The tests failed at 17:27, but the kube-apiserver didn't restart until 22:17 - approximately **5 hours AFTER** the test failures.

### 3. Actual Test Failure Causes

According to `/tmp/review-release-78362/logs/pr78699/ANALYSIS.md`, the tests failed due to:

1. **subnet-lifecycle**: HTTP/2 GOAWAY mid-test (graceful connection termination)
2. **virtual-network-lifecycle**: Kubernetes API unreachable (connection refused to 10.128.0.1:443)
3. **ci-delete-during-provision**: Pod initialization timeout (48 minutes)

These are CI infrastructure failures, NOT related to certificate rotation.

## Certificate Rotation Mechanism

### OpenShift Certificate Rotation Process

OpenShift automatically rotates certificates based on configured periods:

```go
monthPeriod to 720h0m0s (30 days)
yearPeriod to 8760h0m0s (365 days)
tenMonthPeriod to 7008h0m0s (292 days)
```

When a certificate reaches its refresh deadline, the kube-apiserver-operator:
1. Detects the expired refresh time
2. Generates new certificate/key pairs
3. Creates a new secret (e.g., `localhost-recovery-serving-certkey-10`)
4. Triggers a new revision rollout via installer pod
5. The installer pod updates static pod manifests
6. kubelet detects manifest changes and restarts the kube-apiserver pod
7. Brief API downtime during pod restart (~30-60 seconds typical)

### Certificates Rotated

From the installer-10 logs:
- `etcd-client-10`
- `localhost-recovery-client-token-10`
- `localhost-recovery-serving-certkey-10`
- `webhook-authenticator-10`
- `encryption-config-10` (optional, not found)

Plus configmaps:
- `bound-sa-token-signing-certs-10`
- `config-10`
- `etcd-serving-ca-10`
- And 20+ other configuration objects

## Risk Assessment

### When Certificate Rotation COULD Cause Failures

The theory is VALID in principle:
- Golden image age: 19 days (cluster created April 13)
- Certificate refresh deadline: April 29 13:43:53
- Time between refresh deadline and rotation: ~3.5 days

If a test runs EXACTLY when the rotation happens, it would see:
- API server unavailable for 30-60 seconds
- Connection failures during the restart window
- Test timeouts if retries are insufficient

### Window of Vulnerability

The certificate rotation timing is deterministic:
- Certificates have a 30-day refresh period
- Rotation happens when `now > refreshTime`
- The kube-apiserver-operator checks continuously
- Once triggered, rollout completes in ~1-2 minutes

For a golden image that's 5+ days old with certificates past their refresh time, rotation COULD trigger:
- Immediately on first boot (if operator hasn't run yet)
- During any controller sync (continuous reconciliation)
- Unpredictably, making it appear "intermittent"

## Conclusion

### Theory Validation
The certificate rotation theory is MECHANICALLY CORRECT:
- Aged golden images DO have certificates past refresh deadlines
- Certificate rotation DOES trigger kube-apiserver restarts
- Restarts DO cause brief API unavailability

### But NOT the Root Cause This Time
The specific test failures analyzed (May 2, 17:27 UTC) were NOT caused by certificate rotation because:
- The kube-apiserver restart happened 5 hours AFTER the tests failed
- The failures were due to unrelated CI infrastructure issues

### Recommendation

To eliminate certificate rotation as a FUTURE cause of intermittent failures:

1. **Rebuild Golden Images More Frequently**
   - Current: 19+ days old (far past refresh deadlines)
   - Recommended: Rebuild every 7-14 days maximum
   - Or: Trigger rebuild when certificates are within 5 days of refresh deadline

2. **Pre-warm Certificate Rotation**
   - After creating golden image, let it run for 1-2 hours
   - Allow any pending certificate rotations to complete
   - Snapshot AFTER rotation stabilizes
   - This ensures the image starts with fresh certificates

3. **Monitor Certificate Ages**
   - Add check in golden-setup to report certificate ages
   - Warn if any cert is past its refresh deadline
   - Fail fast instead of allowing unpredictable rotation during tests

4. **Add GOLDEN_OCP_VERSION Tracking**
   - Already recommended in task #7
   - Track when cluster was created, not just OCP version
   - Use creation timestamp to calculate certificate age

## Evidence Files

All evidence collected from:
- **Beaker host**: root@rdu-infra-edge-07.infra-edge.lab.eng.rdu2.redhat.com
- **Hub kubeconfig**: /data/golden-debug/hub/hub-kubeconfig
- **Test logs**: /tmp/review-release-78362/logs/pr78699/

Commands used:
```bash
export KUBECONFIG=/data/golden-debug/hub/hub-kubeconfig

# Cluster operator status
oc get co kube-apiserver -o yaml

# Pods in kube-apiserver namespace
oc get pods -n openshift-kube-apiserver -o wide

# Certificate secrets
oc get secrets -n openshift-kube-apiserver | grep cert

# Operator logs showing rotation trigger
oc logs -n openshift-kube-apiserver-operator kube-apiserver-operator-9466fd8cf-8bcqp --since=9h

# Installer pod logs
oc logs -n openshift-kube-apiserver installer-10-test-infra-cluster-d55276d8-master-0

# QCOW2 file timestamps
stat /data/golden-debug/hub/hub-os.qcow2
```

## Next Steps

1. Check if OTHER test runs (not the May 2nd 17:27 failures) correlate with certificate rotation timing
2. Implement golden image rebuild frequency based on certificate refresh periods
3. Add certificate age monitoring to golden-setup script
4. Consider pre-warming new golden images to trigger rotation before snapshot
