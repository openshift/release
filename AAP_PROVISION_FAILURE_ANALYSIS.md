# AAP Provision Failure Analysis - PR 78362 and Experiments

## Summary

All 4 PRs show IDENTICAL provision failures:
- Status reaches 'Failed' (not timeout or empty)
- Test timeout after 600s waiting for status='Succeeded'
- AAP pods are Running and healthy in all tests
- Fulfillment controller starts successfully
- No connection errors to AAP during setup

## Test Results

### PR 78362 (Original)
Run: 2049816273025503232
Error: `TimeoutError: provision Succeeded for vm-vtd68 — timeout after 600s, last value: 'Failed'`

### PR 78699 (firewalld)
Run: 2050270327019147264
Error: `TimeoutError: provision Succeeded for vm-vtd68 — timeout after 600s, last value: 'Failed'`

### PR 78701 (operator restart)
Run: 2050270186350579712
Error: `TimeoutError: provision Succeeded for vm-7dv2g — timeout after 600s, last value: 'Failed'`

### PR 78702 (diagnostics)
Run: 2050270307826012160
Test log decompression failed - unable to analyze

## Setup Phase - AAP Health

All PRs show healthy AAP infrastructure:

### AAP Pods (All Running)
```
osac-aap-controller-task           4/4     Running     22 restarts
osac-aap-controller-web            3/3     Running     20-21 restarts
osac-aap-eda-activation-worker     1/1     Running     3 restarts (2 replicas)
osac-aap-eda-api                   3/3     Running     9 restarts
osac-aap-eda-default-worker        1/1     Running     3 restarts (2 replicas)
osac-aap-eda-event-stream          2/2     Running     6 restarts
osac-aap-eda-scheduler             1/1     Running     3 restarts (2 replicas)
osac-aap-gateway                   2/2     Running     6 restarts
osac-aap-postgres-15-0             1/1     Running     3 restarts
osac-aap-redis-0                   1/1     Running     3 restarts
fulfillment-rest-gateway           1/1     Running     5-6 restarts
osac-operator-controller-manager   1/1     Running     3 restarts
```

### Fulfillment Controller Logs

Normal startup pattern observed:
1. gRPC server starts
2. Initial "no healthy upstream" errors (first 6 seconds)
3. Server becomes ready
4. All reconcilers start successfully
5. No errors after startup

This is EXPECTED behavior - the fulfillment controller checks if the REST gateway is ready before proceeding.

## Key Findings

1. **Provision Status**: The ComputeInstance CR's `.status.provisionStatus` reaches 'Failed', not 'Pending' or empty
2. **AAP Health**: All AAP pods are Running in all test runs
3. **Consistent Failure**: All 3 experiments (firewalld, operator restart, diagnostics) show the SAME failure
4. **Missing Data**: The test logs do NOT show WHY provision failed - only that the status is 'Failed'

## What's Missing

The logs analyzed do NOT contain:
- The REASON for the 'Failed' provision status
- AAP job template execution logs
- AAP job ID that was launched
- Operator logs DURING the provision attempt (only startup logs available)
- The actual HTTP error from AAP API
- ComputeInstance CR's `.status.message` or `.status.conditions`

## Root Cause Hypothesis

Based on the pattern, the most likely causes are:

1. **AAP Job Template Failure**: The AAP job template runs but fails during execution
   - Need to check: AAP job logs, job output, failure reason in AAP UI

2. **AAP Route/Ingress Issue**: The operator can reach AAP initially, but requests fail
   - Need to check: Route `osac-aap-osac-e2e-ci.apps.test-infra-cluster-d55276d8.redhat.com`
   - Need to verify: HTTPS connectivity from operator pod to AAP gateway

3. **Ansible Playbook Failure**: The job template executes but the playbook fails
   - Need to check: What playbook is being run? What's the failure in the playbook output?

## Next Steps to Diagnose

1. **Get PR 78702 test logs**: Decompress and analyze the diagnostics PR logs
2. **Check ComputeInstance CR status**: Need `kubectl describe computeinstance <name>` output
3. **Get AAP job logs**: Need to see the AAP job execution logs for the failed provision
4. **Check operator logs DURING provision**: The setup logs only show startup, need logs from the actual provision attempt
5. **Verify AAP route**: Test connectivity to `https://osac-aap-osac-e2e-ci.apps.test-infra-cluster-d55276d8.redhat.com/api/controller`

## File Locations

Setup logs (decompressed):
- /tmp/review-release-78362/logs/pr78699/setup-build-log-decompressed.txt
- /tmp/review-release-78362/logs/pr78701/setup-build-log-decompressed.txt
- /tmp/review-release-78362/logs/pr78702/setup-build-log-decompressed.txt (failed to decompress)

Test logs (decompressed):
- /tmp/review-release-78362/logs/pr78699/test-decompressed.txt
- /tmp/review-release-78362/logs/pr78701/test-decompressed.txt
- /tmp/review-release-78362/logs/pr78702/test-decompressed.txt (not available)
