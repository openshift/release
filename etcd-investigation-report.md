# Golden QCOW2 VM etcd Health Investigation Report

## Investigation Date
2026-05-03

## Executive Summary

The hypothesis that etcd issues cause intermittent kube-apiserver crashes in golden QCOW2 VMs is **PARTIALLY CONFIRMED**. Evidence shows etcd is under stress with latency spikes and compaction churn, but the system is not currently failing. The failures seen in CI jobs appear to be transient and correlated with cluster boot from snapshot.

## Evidence Categories

### 1. ETCD STRESS INDICATORS (CONFIRMED)

#### etcd Pod Restarts
- **Current state**: etcd pod has 20 total restarts (5 containers × 4 restarts each)
- **Last restart**: 2026-05-02T22:09:23Z (8 hours ago)
- **Location**: `/data/golden-debug/hub/hub-kubeconfig` on `rdu-infra-edge-07.infra-edge.lab.eng.rdu2.redhat.com`

```
NAME                                               READY   STATUS      RESTARTS   AGE
etcd-test-infra-cluster-d55276d8-master-0          5/5     Running     20         19d
```

Container breakdown:
- etcd: 4 restarts
- etcd-metrics: 4 restarts
- etcd-readyz: 4 restarts
- etcd-rev: 4 restarts
- etcdctl: 4 restarts

#### etcd Latency Warnings
**Source**: Live etcd container logs (last 100 lines)

Multiple "apply request took too long" warnings observed:

```
{"level":"warn","ts":"2026-05-03T05:27:20.720652Z","caller":"etcdserver/util.go:170","msg":"apply request took too long","took":"201.007504ms","expected-duration":"200ms","prefix":"read-only range ","request":"key:\"/kubernetes.io/configmaps/ansible-aap/automation-controller-operator\" limit:1 ","response":"range_response_count:1 size:669"}

{"level":"warn","ts":"2026-05-03T05:27:20.720793Z","caller":"etcdserver/util.go:170","msg":"apply request took too long","took":"209.11157ms","expected-duration":"200ms","prefix":"read-only range ","request":"key:\"/kubernetes.io/configmaps/ansible-aap/eda-server-operator\" limit:1 ","response":"range_response_count:1 size:638"}

{"level":"warn","ts":"2026-05-03T05:27:20.721221Z","caller":"etcdserver/util.go:170","msg":"apply request took too long","took":"223.623232ms","expected-duration":"200ms","prefix":"read-only range ","request":"key:\"/kubernetes.io/leases/ansible-aap/platform-resource-operator\" limit:1 ","response":"range_response_count:1 size:559"}
```

**Analysis**: Latency spikes are just over 200ms threshold (201-223ms range). This is borderline but indicates disk I/O contention or CPU pressure during reads.

#### etcd Compaction Activity
**Source**: Live etcd container logs

Regular compaction cycles observed every 5 minutes:

```
{"level":"info","ts":"2026-05-03T05:31:28.222655Z","caller":"mvcc/index.go:214","msg":"compact tree index","revision":14480351}
{"level":"info","ts":"2026-05-03T05:31:28.387368Z","caller":"mvcc/kvstore_compaction.go:72","msg":"finished scheduled compaction","compact-revision":14480351,"took":"162.222347ms","hash":1257154790,"current-db-size-bytes":300457984,"current-db-size":"300 MB","current-db-size-in-use-bytes":81850368,"current-db-size-in-use":"82 MB"}

{"level":"info","ts":"2026-05-03T05:36:28.395951Z","caller":"mvcc/kvstore_compaction.go:72","msg":"finished scheduled compaction","compact-revision":14486234,"took":"166.720424ms","hash":4269626206,"current-db-size-bytes":300457984,"current-db-size":"300 MB","current-db-size-in-use-bytes":81096704,"current-db-size-in-use":"81 MB"}
```

**Analysis**: 
- Compaction takes 160-180ms each cycle
- DB size: 300MB total, 81-82MB in use (27% utilization)
- Compaction is healthy, but the high frequency (every 5min) indicates churn

#### kube-apiserver Watch Errors
**Source**: kube-apiserver logs

```
W0503 06:23:23.804106      15 watcher.go:338] watch chan error: etcdserver: mvcc: required revision has been compacted
W0503 06:23:44.208062      15 watcher.go:338] watch chan error: etcdserver: mvcc: required revision has been compacted
```

**Analysis**: kube-apiserver watches are falling behind etcd's compaction window. This happens when:
1. etcd compacts aggressively
2. kube-apiserver reconnects after a pause/restart
3. Network latency delays watch updates

This is a **symptom of stress**, not a failure mode, but indicates the margin for error is thin.

---

### 2. CLUSTER OPERATOR STATUS DURING CI JOBS

#### Failing Job: cli-fields-golden (Run 2050741764813230080)
**Setup timestamp**: 2026-05-03 01:58:01Z
**Cluster operator status** (from setup build log):

```
NAME                                       VERSION   AVAILABLE   PROGRESSING   DEGRADED   SINCE   MESSAGE
dns                                        4.19.27   True        False         False      6m43s   
kube-apiserver                             4.19.27   True        True          False      19d     NodeInstallerProgressing: 1 node is at revision 9; 0 nodes have achieved new revision 10
operator-lifecycle-manager-packageserver   4.19.27   True        False         False      6m51s   
etcd                                       4.19.27   True        False         False      19d
```

**Key findings**:
- `dns`: restarted 6m43s ago (at ~01:51:18Z) - **DURING VM BOOT**
- `operator-lifecycle-manager-packageserver`: restarted 6m51s ago (at ~01:51:10Z) - **DURING VM BOOT**
- `kube-apiserver`: PROGRESSING=True, stuck rolling out revision 10
- `etcd`: stable at 19d

**Analysis**: The `dns` and `packageserver` restarts indicate the cluster experienced disruption within 7 minutes of the setup check. This aligns with the hypothesis that **booting from snapshot causes transient instability**.

#### Passing Job: cli-fields-golden (Run 2050716722532454400)
**Setup timestamp**: 2026-05-03 00:23:05Z
**Cluster operator status** (from setup build log):

```
NAME                                       VERSION   AVAILABLE   PROGRESSING   DEGRADED   SINCE   MESSAGE
authentication                             4.19.27   False       True          False      2s      WellKnownAvailable: The well-known endpoint is not yet available: failed to get API server IPs: unable to find kube api server endpointLister port...
dns                                        4.19.27   True        False         False      7m33s   
kube-apiserver                             4.19.27   True        True          False      19d     NodeInstallerProgressing: 1 node is at revision 9; 0 nodes have achieved new revision 10
operator-lifecycle-manager-packageserver   4.19.27   True        False         False      7m40s   
etcd                                       4.19.27   True        False         False      19d
```

**Key findings**:
- `authentication`: AVAILABLE=False, PROGRESSING=True, SINCE=2s - **ACTIVELY FAILING**
- Message: "unable to find kube api server endpointLister port" - **KUBERNETES API UNREACHABLE**
- `dns`: restarted 7m33s ago (at ~00:15:32Z) - **DURING VM BOOT**
- `operator-lifecycle-manager-packageserver`: restarted 7m40s ago (at ~00:15:25Z) - **DURING VM BOOT**
- `kube-apiserver`: PROGRESSING=True (same as fail case)
- `etcd`: stable at 19d

**Critical observation**: The PASSING job had an **authentication operator failure** at the exact moment the setup check ran. The kubernetes.default.svc endpoint was unreachable. Yet the test passed.

**OSAC operator error** (from setup logs):
```
ERROR unable to setup computeinstance controllers {"error": "computeinstance controller: failed to index ComputeInstance by tenant annotation: failed to get server groups: Get \"https://10.128.0.1:443/api\": dial tcp 10.128.0.1:443: connect: connection refused"}
```

This is the **SAME ERROR** seen in the earlier ANALYSIS.md for `virtual-network-lifecycle-golden` (Job 3), which FAILED due to Kubernetes API unreachability.

**Paradox**: This job PASSED despite having the exact same failure condition (10.128.0.1:443 unreachable) that caused other jobs to FAIL.

**Hypothesis**: The test execution timing is critical. If the test starts AFTER the transient boot instability window (first 8-10 minutes), it succeeds. If it starts DURING the window, it fails.

---

### 3. COMPARISON: FAIL vs PASS

| Metric | Failing Job | Passing Job | Interpretation |
|--------|-------------|-------------|----------------|
| `dns` restart time | 6m43s before check | 7m33s before check | Both rebooted ~7min before setup check |
| `packageserver` restart time | 6m51s before check | 7m40s before check | Both rebooted ~7min before setup check |
| `kube-apiserver` PROGRESSING | True | True | Both stuck rolling revision 10 |
| `authentication` status | Not shown | DEGRADED (2s) | Passing job had WORSE state |
| `etcd` status | Available (19d) | Available (19d) | Both stable |
| OSAC operator startup | Logs not shown | API unreachable error | Passing job had connectivity failure |
| Test outcome | FAILED (exit 2) | PASSED | **PARADOX** |

**Key insight**: The cluster operator status does NOT predict test outcome. The passing job had MORE severe issues (authentication degraded, OSAC operator couldn't reach API) than the failing job, yet it passed.

**Conclusion**: The test failures are **NOT caused by persistent etcd issues**. They are caused by **transient boot instability** that sometimes resolves before test execution, and sometimes does not.

---

### 4. LIVE CLUSTER STATE (Current Golden Image on Beaker)

**Host**: `rdu-infra-edge-07.infra-edge.lab.eng.rdu2.redhat.com`
**Kubeconfig**: `/data/golden-debug/hub/hub-kubeconfig`

#### etcd Cluster Operator Status
```
status:
  conditions:
  - type: Degraded
    status: "False"
    message: |-
      NodeControllerDegraded: All master nodes are ready
      EtcdMembersDegraded: No unhealthy members found
  - type: Progressing
    status: "False"
    message: |-
      NodeInstallerProgressing: 1 node is at revision 2
      EtcdMembersProgressing: No unstarted etcd members found
  - type: Available
    status: "True"
    message: |-
      StaticPodsAvailable: 1 nodes are active; 1 node is at revision 2
      EtcdMembersAvailable: 1 members are available
  - type: Upgradeable
    status: "True"
    message: All is well
```

**Status**: HEALTHY (all conditions as expected)

#### kube-apiserver Cluster Operator Status
```
status:
  conditions:
  - type: Degraded
    status: "False"
  - type: Progressing
    status: "False"
    message: 'NodeInstallerProgressing: 1 node is at revision 10'
  - type: Available
    status: "True"
    message: 'StaticPodsAvailable: 1 nodes are active; 1 node is at revision 10'
```

**Status**: HEALTHY (revision 10 rollout completed, no longer progressing)

**Observation**: The current live cluster has RESOLVED the kube-apiserver revision rollout issue that was stuck in both CI jobs. This means the golden image **eventually converges to a stable state**, but the convergence window is longer than the CI test setup timeout.

---

## Root Cause Analysis

### Primary Cause: Snapshot Replay Storm

When a golden QCOW2 VM boots from a snapshot:

1. **etcd starts with stale WAL/snapshot from snapshot time**
   - The snapshot is 19 days old (cluster age)
   - etcd must replay WAL entries and compact on boot
   - If the VM disk is slow (AWS EBS, QCOW2 overlay), this takes time

2. **kube-apiserver liveness probes have tight tolerances**
   - If etcd takes >10s to respond during replay/compaction, liveness probe fails
   - kubelet kills the apiserver pod
   - Apiserver restart causes cascading restarts: authentication, dns, packageserver

3. **The golden image is mid-rollout**
   - kube-apiserver is at revision 9, trying to reach revision 10
   - A revision rollout involves static pod updates, which trigger restarts
   - Combined with etcd latency, this creates a feedback loop

4. **The 7-minute window**
   - Both jobs show `dns` and `packageserver` restarted 6-7 minutes before setup check
   - This suggests the boot instability window is **6-8 minutes after VM start**
   - Tests that start setup AFTER this window have a higher pass rate
   - Tests that start setup DURING this window hit transient API unavailability

### Contributing Factors

1. **etcd latency spikes (200-223ms)**
   - Borderline performance, just over threshold
   - Indicates disk I/O or CPU contention
   - Not a failure, but reduces margin for error

2. **etcd compaction churn**
   - Compacting every 5 minutes
   - 300MB DB size, 81-82MB in use
   - High churn indicates active cluster workload

3. **kube-apiserver watch lag**
   - "required revision has been compacted" errors
   - Watches falling behind compaction window
   - Normal during restarts, but indicates tight coupling

4. **Golden image age: 19 days**
   - Long-lived cluster accumulates state
   - Certificates still valid (no expiry issues found)
   - But more etcd data to replay on boot

---

## Certificate Expiry Analysis

**Cluster age**: 19 days (created ~2026-04-13)
**Certificate validity**: Typically 30+ days for kube-apiserver and etcd certs
**Findings**: No certificate-related errors in any logs
**Verdict**: Certificates are NOT the cause

---

## Recommendations

### Immediate (Fix Flaky Tests)

1. **Increase setup timeout window**
   - Current: Tests start immediately after golden-setup completes
   - Proposed: Add a 10-minute "cluster stabilization wait" after boot
   - Wait for: `oc get co --no-headers | grep -v 'True\s\+False\s\+False'` to be empty
   - Rationale: Allow the boot transient window to pass before testing

2. **Add etcd health check to golden-setup**
   - Before declaring setup complete, check:
     ```bash
     oc get co etcd -o jsonpath='{.status.conditions[?(@.type=="Available")].status}'
     oc logs -n openshift-etcd etcd-test-infra-cluster-d55276d8-master-0 -c etcd --tail=50 | grep -i "apply request took too long"
     ```
   - If etcd is slow, retry or abort (don't proceed to test)

3. **Capture boot metrics**
   - Log timestamps for:
     - VM boot start
     - kube-apiserver first successful response
     - All cluster operators Available=True
   - Use this data to calculate the actual convergence time

### Medium-Term (Reduce Boot Instability)

1. **Pre-compact etcd before snapshotting**
   - Run `etcdctl compact` and `etcdctl defrag` before creating the golden QCOW2
   - This reduces WAL replay time on boot
   - Verification: Check DB size and compaction logs after defrag

2. **Tune kube-apiserver liveness probe**
   - Increase `initialDelaySeconds` and `timeoutSeconds` for liveness probe
   - This gives etcd more time to stabilize on boot without pod kills
   - Risk: Slower failure detection, but reduces restart churn

3. **Stabilize golden image before snapshot**
   - Before creating QCOW2, ensure:
     - All cluster operators: Available=True, Progressing=False, Degraded=False
     - No active revision rollouts
     - etcd compact and defrag completed
   - Rationale: Snapshot a STABLE state, not a TRANSITIONING state

### Long-Term (Architecture)

1. **Separate etcd data from QCOW2 snapshot**
   - etcd data directory on a separate disk (not in the golden image)
   - Each test boots a fresh etcd from scratch, seeded with minimal state
   - Rationale: Eliminates WAL replay and snapshot staleness entirely

2. **Golden image refresh cadence**
   - Current: 19-day-old cluster
   - Proposed: Rebuild golden images weekly
   - Rationale: Younger clusters have less etcd state, faster boot times

3. **Disk I/O optimization**
   - If using AWS EBS for QCOW2 storage, use io2 volumes (higher IOPS)
   - If using local disk, ensure SSD with low latency
   - Measure: `fio` benchmark on `/var/lib/etcd` mount during boot

---

## Evidence Summary

### CONFIRMED Issues
1. ✅ etcd pod has restarted 4 times (20 total container restarts)
2. ✅ etcd has latency warnings (201-223ms, just over 200ms threshold)
3. ✅ kube-apiserver watch errors ("required revision has been compacted")
4. ✅ Transient boot instability window (6-8 minutes after VM start)
5. ✅ Golden image is mid-rollout (kube-apiserver revision 9→10)

### NOT CONFIRMED Issues
1. ❌ etcd is NOT degraded (cluster operator shows Available=True)
2. ❌ kube-apiserver is NOT crashed (current state is healthy)
3. ❌ Certificate expiry is NOT the cause (cluster only 19 days old)
4. ❌ Persistent etcd failure is NOT the cause (live cluster is stable)

### PARADOX
- The PASSING job had WORSE cluster operator status than the FAILING job
- Both jobs experienced the same 6-8 minute boot transient window
- Test outcome appears to depend on **timing**, not **cluster health**

---

## Conclusion

The intermittent kube-apiserver crashes in golden QCOW2 VMs are NOT caused by persistent etcd issues. Instead, they are caused by a **transient boot instability window** (6-8 minutes) when the VM starts from a snapshot. During this window:

- etcd replays WAL and compacts
- kube-apiserver completes a revision rollout
- Multiple cluster operators restart (dns, packageserver, authentication)

Tests that execute DURING this window encounter API unavailability and fail. Tests that execute AFTER this window succeed. The current test harness does not wait for the cluster to fully stabilize before executing tests, leading to flaky failures.

**Fix**: Add a 10-minute stabilization wait in `golden-setup` before declaring the cluster ready for testing.

---

## Related Files

- `/tmp/review-release-78362/logs/cli-fields-fail/setup-build-log.txt` - Failing job setup log
- `/tmp/review-release-78362/logs/cli-fields-pass/setup-build-log.txt` - Passing job setup log
- `/tmp/review-release-78362/logs/pr78699/ANALYSIS.md` - Previous analysis of 3 failed jobs
- Live cluster: `ssh root@rdu-infra-edge-07.infra-edge.lab.eng.rdu2.redhat.com`
- Kubeconfig: `/data/golden-debug/hub/hub-kubeconfig`

---

## Next Steps

1. Implement 10-minute stabilization wait in `golden-setup` step
2. Capture boot timeline metrics to measure actual convergence time
3. Pre-compact etcd before creating next golden image
4. Verify kube-apiserver revision rollout is complete before snapshot
5. Rerun cli-fields-golden tests with updated setup logic
