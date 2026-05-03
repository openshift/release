# AAP Error Analysis for 4 Experiment PRs

## Summary

Analyzed CI artifacts from 4 experiment PRs that test the golden compute instance creation flow. Found that **provision failures occurred but NOT due to CrashLoopBackOff** in AAP pods. The root cause appears to be related to missing or empty job templates.

## PR Status

| PR | Run ID | Test Status | AAP Pods Status | Provision Status |
|----|--------|-------------|-----------------|------------------|
| 78362 | 2049816273025503232 | Blocked (sensitive info removed) | All Running | Not tested / inconclusive |
| 78699 | 2050270327019147264 | **FAILED** | All Running | **FAILED after 600s timeout** |
| 78701 | 2050270186350579712 | **FAILED** | All Running | **FAILED after 600s timeout** |
| 78702 | 2050270307826012160 | Blocked (sensitive info removed) | All Running | Not tested / inconclusive |

## Key Findings

### 1. AAP Pods Are Healthy

All AAP components were **RUNNING** in all 4 PRs at the time of testing:

```
osac-aap-controller-task-...    4/4     Running     22 (103s ago)   
osac-aap-controller-web-...     3/3     Running     21 (89s ago)    
osac-aap-gateway-...            2/2     Running     6               
osac-aap-postgres-15-0          1/1     Running     3               
osac-aap-redis-0                1/1     Running     3               
```

**No CrashLoopBackOff detected.**

### 2. Provision Failures in PRs 78699 and 78701

Both PRs timed out waiting for provision to succeed:

**PR 78699:**
```
TimeoutError: provision Succeeded for vm-vtd68 — timeout after 600s, last value: 'Failed'
```

**PR 78701:**
```
TimeoutError: provision Succeeded for vm-7dv2g — timeout after 600s, last value: 'Failed'
```

The ComputeInstance CR status transitioned to `Failed` instead of `Succeeded`.

### 3. Empty Job Templates in PR 78701

PR 78701 shows the operator starting with **empty provision/deprovision templates**:

```
2026-05-01T18:42:29Z	INFO	setup	using AAP direct provider	
{"url": "https://osac-aap-osac-e2e-ci.apps.test-infra-cluster-d55276d8.redhat.com/api/controller", 
 "provisionTemplate": "", 
 "deprovisionTemplate": "", 
 "templatePrefix": "osac", 
 "statusPollInterval": "30s", 
 "insecureSkipVerify": true}
```

This indicates the operator was configured to use AAP but **could not find the job templates** it needed to trigger provisioning.

### 4. PRs 78362 and 78702 Status Unknown

- Test logs show "This file contained potentially sensitive information and has been removed"
- Unable to determine if provision was attempted or what the outcome was
- No operator logs showing AAP provider setup

## Root Cause Hypothesis

The provision failures are likely due to:

1. **Missing AAP Job Templates**: The operator expects job templates named with the `osac` prefix (e.g., `osac-provision-vm`, `osac-deprovision-vm`) but they may not exist in AAP
2. **AAP Bootstrap Failures**: Multiple `aap-bootstrap-*` pods are in Error state, which may indicate the bootstrap process that creates job templates failed
3. **Template Discovery Issue**: The operator may be unable to discover or access the templates even if they exist

## Next Steps to Debug

1. **Check AAP Job Templates**:
   ```bash
   oc exec -n osac-e2e-ci osac-aap-controller-web-... -- \
     awx job_templates list --name "osac*"
   ```

2. **Review aap-bootstrap Logs**:
   ```bash
   oc logs -n osac-e2e-ci aap-bootstrap-vjwb8  # The one that Completed
   oc logs -n osac-e2e-ci aap-bootstrap-49m7z  # One that Errored
   ```

3. **Check Operator Logs for Provision Attempt**:
   - Look for logs from the operator attempting to launch AAP jobs
   - Check for HTTP errors communicating with AAP API

4. **Verify AAP API Connectivity**:
   ```bash
   curl -k https://osac-aap-osac-e2e-ci.apps.test-infra-cluster-d55276d8.redhat.com/api/controller/ping
   ```

5. **Check ComputeInstance CR Status**:
   ```bash
   oc get computeinstance -n osac-e2e-ci vm-vtd68 -o yaml
   oc get computeinstance -n osac-e2e-ci vm-7dv2g -o yaml
   ```
   Look for the `.status.conditions` field to see why provision failed.

## Files Analyzed

- `/tmp/review-release-78362/pr-78362/assisted-ofcir-setup.log`
- `/tmp/review-release-78362/pr-78362/osac-project-golden-setup.log`
- `/tmp/review-release-78362/pr-78699/assisted-ofcir-setup.log`
- `/tmp/review-release-78362/pr-78699/osac-project-golden-setup.log`
- `/tmp/review-release-78362/pr-78699/test-unzipped.log`
- `/tmp/review-release-78362/pr-78701/assisted-ofcir-setup.log`
- `/tmp/review-release-78362/pr-78701/osac-project-golden-setup.log`
- `/tmp/review-release-78362/pr-78701/test-unzipped.log`
- `/tmp/review-release-78362/pr-78702/assisted-ofcir-setup.log`
- `/tmp/review-release-78362/pr-78702/osac-project-golden-setup.log`

## Artifacts Not Available

- ComputeInstance CR YAML from failed runs (cir.json was empty in ofcir-gather)
- Operator controller logs showing provision attempts
- AAP job template list
- aap-bootstrap pod logs
