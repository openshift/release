---
description: Debug sandboxed-containers-operator CI step failures using /pj-rehearse
args: "[job_name]"
allowed-tools:
  - Read
  - Edit
  - Write
  - Glob
  - AskUserQuestion
  - Bash(make update)
  - Bash(git *)
  - Bash(.claude/scripts/monitor-validation.sh *)
  - Bash(.claude/scripts/analyze-validation.sh *)
  - Bash(.claude/scripts/list-affected-jobs.sh *)
  - Bash(.claude/scripts/verify-rehearsal-started.sh *)
  - Bash(.claude/scripts/monitor-rehearsal.sh *)
  - Bash(.claude/scripts/analyze-prowjob.sh *)
  - Bash(.claude/scripts/prow-fetch.sh *)
  - Bash(.claude/scripts/trigger-rehearsal.sh *)
  - Bash(ps aux | grep *)
  - Bash(kill *)
  - Bash(sleep *)
  - Bash(date)
  - Bash(wc *)
  - Bash(cat /tmp/*)
  - Bash(tail /tmp/*)
  - Bash(gh pr *)
  - Bash(find ci-operator/step-registry/sandboxed-containers-operator *)
  - Bash(find ci-operator/config/openshift/sandboxed-containers-operator *)
  - Bash(find ci-operator/jobs/openshift/sandboxed-containers-operator *)
---

# OSC Step Debug - Sandboxed Containers Operator CI Step Debugging

Debug and fix sandboxed-containers-operator (OSC) CI step failures using /pj-rehearse for rapid iteration.

**Arguments**: 
- `job_name` (optional): Specific OSC job to debug (e.g., "azure-ipi-coco", "aws-ipi-peerpods")

## Scope

**This skill is ONLY for sandboxed-containers-operator CI configuration:**
- Files in `ci-operator/step-registry/sandboxed-containers-operator/`
- Config in `ci-operator/config/openshift/sandboxed-containers-operator/`
- OSC test jobs (CoCo, Kata, PeerPods)

**DO NOT use this skill for:**
- Other repositories or components
- Core Prow infrastructure changes
- Changes outside the sandboxed-containers-operator scope

## Overview

This skill provides a systematic workflow for debugging OSC CI step failures:

1. **Identify** the failing step in `ci-operator/step-registry/sandboxed-containers-operator/`
2. **Analyze** error patterns in Prow build logs
3. **Fix** issues based on common OSC patterns:
   - OLM operator installation (trustee, OSC)
   - CatalogSource readiness
   - Base images and tool availability
   - Network restrictions
   - Environment variables and secrets
   - kbs-client connectivity
   - Kata/CoCo/PeerPods specific issues
4. **Test** changes using /pj-rehearse
5. **Monitor** long-running rehearsals with background scripts
6. **Iterate** until the job passes

**Common OSC job types:**
- `azure-ipi-coco` - Confidential Containers on Azure
- `aws-ipi-coco` - Confidential Containers on AWS
- `azure-ipi-kata` - Kata Containers on Azure
- `aws-ipi-peerpods` - Peer Pods on AWS
- `aro-ipi-peerpods` - Peer Pods on ARO

## Mandatory Script Usage

**CRITICAL:** This skill MUST use wrapper scripts for ALL operations. Direct `curl`, `gh`, and ad-hoc loops are NOT allowed.

**Why scripts are mandatory:**
1. **Consistency** - Same behavior every time
2. **Maintainability** - Fix bugs in one place
3. **Readability** - Clear what operation is being performed
4. **Pre-approved** - Scripts are in allowed-tools, ad-hoc commands are not

**Required scripts (pre-approved in allowed-tools):**

### Validation Scripts

**`.claude/scripts/monitor-validation.sh`** - Monitor PR validation checks:
```bash
# Monitor with defaults (30 checks x 2min = 60min max)
.claude/scripts/monitor-validation.sh <PR>

# Custom interval and max checks
.claude/scripts/monitor-validation.sh <PR> 20 90
```
**Returns:** Exit 0 (all pass), Exit 1 (failures found), Exit 2 (timeout)

**`.claude/scripts/analyze-validation.sh`** - Analyze validation failures:
```bash
.claude/scripts/analyze-validation.sh <PR>
```
**Returns:** Fetches and displays build logs from failing checks

**`.claude/scripts/list-affected-jobs.sh`** - List jobs affected by PR:
```bash
# List all affected jobs
.claude/scripts/list-affected-jobs.sh <PR>

# Filter for specific pattern
.claude/scripts/list-affected-jobs.sh <PR> "azure-ipi-coco"
```

### Rehearsal Scripts

**`.claude/scripts/trigger-rehearsal.sh`** - Trigger a rehearsal:
```bash
.claude/scripts/trigger-rehearsal.sh <PR> <FULL_JOB_NAME>
```

**`.claude/scripts/monitor-rehearsal.sh`** - Monitor rehearsal execution:
```bash
# Monitor specific step, then continue to completion
.claude/scripts/monitor-rehearsal.sh <PR> <SHORT_JOB_NAME> [DURATION_HOURS] [CHECK_INTERVAL] [STEP_NAME] [ARTIFACT_WAIT] [CONTINUE_AFTER_STEP]

# Example: Monitor install-trustee-operator step
.claude/scripts/monitor-rehearsal.sh 79996 "aws-ipi-coco" 3 300 "install-trustee-operator" 120 true
```

### Analysis Scripts

**`.claude/scripts/analyze-prowjob.sh`** - Analyze job failures:
```bash
.claude/scripts/analyze-prowjob.sh <PROW_JOB_URL>
```

**`.claude/scripts/prow-fetch.sh`** - Fetch Prow/GCS data:
```bash
# Get PR checks
.claude/scripts/prow-fetch.sh pr-checks <PR> [PATTERN]

# Fetch any Prow/GCS URL
.claude/scripts/prow-fetch.sh <URL>

# Fetch build logs
.claude/scripts/prow-fetch.sh build-log <PR> <JOB_ID> <STEP_NAME>
```

### DO NOT Use Ad-Hoc Loops

❌ **WRONG** - Ad-hoc polling loop:
```bash
for i in {1..10}; do
  gh pr checks 79996 | grep "fail"
  sleep 120
done
```

✅ **RIGHT** - Use the script:
```bash
.claude/scripts/monitor-validation.sh 79996
```
```

## Workflow

### 0. CRITICAL: Active Monitoring Loop

**NEVER wait passively for results. Always use active monitoring loops.**

After ANY action (push, fix, trigger), immediately enter a monitoring loop:

```bash
# Example: After pushing a fix
while true; do
  gh pr checks <PR> --repo openshift/release | grep -E "fail|pending|pass"
  
  # If all passing or new failures detected, break and act
  # Otherwise, wait 2-3 min and check again
  
  sleep 120  # Check every 2 minutes
done
```

**Required monitoring scenarios:**
1. **After pushing validation fixes** - Monitor until all checks pass or new failure detected
2. **After triggering rehearsal** - Monitor until job starts or fails to start
3. **During rehearsal execution** - Monitor step progress continuously
4. **After step completion** - Monitor until full job completes

**Do NOT:**
- ❌ Push a fix and assume it worked
- ❌ Wait for user to tell you something failed
- ❌ Sleep for long periods without checking status
- ❌ Move on to other tasks while waiting

**DO:**
- ✅ Set up monitoring loop immediately after any action
- ✅ Check status every 2-3 minutes
- ✅ Report status changes proactively
- ✅ Investigate failures immediately when detected

### 1. Identify Failing Step

Find the step in the OSC step registry:

```bash
find ci-operator/step-registry/sandboxed-containers-operator -name "*<step-name>*"
```

Common OSC steps:
- `install-trustee-operator` - Install Trustee operator for CoCo
- `env-cm` - Create environment ConfigMap and CatalogSource
- `get-kata-rpm` - Download and install Kata RPM
- `peerpods-param-cm` - Create PeerPods parameter ConfigMap
- `record-metadata` - Record test metadata

### 2. Analyze Failure

Use prowjob-analyzer for OSC-specific analysis:

```bash
.claude/scripts/analyze-prowjob.sh <PROW_URL>
```

The analyzer understands OSC test patterns:
- Metadata extraction (provider, OCP version, workload type)
- Failed step identification
- Test result summaries
- Common failure patterns (RPM installation, operator setup, etc.)

### 3. Common OSC Debugging Patterns

**OLM Operator Installation Issues:**
```yaml
# Wait for CatalogSource readiness
# Check Subscription → InstallPlan → CSV → Deployment stages
```

**CatalogSource not ready:**
```bash
# Add wait loop for brew-catalog or custom CatalogSource
# Poll for READY state before proceeding
```

**Base image issues:**
```yaml
# Use 'from: cli' for oc/kubectl only
# Use 'from: tools' for git, make, python, etc.
```

**Network restrictions:**
```yaml
# OSC CoCo tests require network access for kbs-client
restrict_network_access: false
```

**kbs-client connectivity:**
```bash
# Test resource retrieval
# Check RCA protocol: GET → 401 → POST /auth → POST /attest → GET → 200
```

### 4. File Changes Scope

**Allowed file modifications:**
- `ci-operator/step-registry/sandboxed-containers-operator/**/*`
- `ci-operator/config/openshift/sandboxed-containers-operator/**/*`
- `ci-operator/jobs/openshift/sandboxed-containers-operator/**/*` (generated only)

**NOT allowed:**
- Files outside sandboxed-containers-operator scope
- Core Prow configuration
- Other component repositories

### 5. PR Validation Monitoring (CRITICAL)

**BEFORE triggering any rehearsal, validation MUST pass.**

After pushing any changes to a PR, use the validation monitoring script:

```bash
# Monitor validation (will check every 2 min for up to 60 min)
.claude/scripts/monitor-validation.sh <PR>
```

**The script will:**
- Check validation every 2 minutes (configurable)
- Report status of each validation check
- Exit with code 0 when all pass
- Exit with code 1 when failures detected
- Exit with code 2 on timeout

**Response to exit codes:**

```bash
# Run monitoring
.claude/scripts/monitor-validation.sh 79996

# If exit code 1 (failures detected):
.claude/scripts/analyze-validation.sh 79996
# -> Analyze failures
# -> Fix issues
# -> Commit and push
# -> Re-run monitor-validation.sh

# If exit code 0 (all passed):
# -> Proceed to list affected jobs and trigger rehearsal
```

**Common validation failures:**

1. **ci/prow/owners** - Missing OWNERS file
   - Fix: Create OWNERS file matching sibling directories
   
2. **ci/prow/step-registry-metadata** - Missing or incorrect .metadata.json
   - Fix: Create `.metadata.json` with exact format (no trailing newline!)
   - Use other step metadata files as reference
   - Common issue: File must end without trailing newline
   
3. **ci/prow/step-registry-shellcheck** - Shell script issues
   - Fix: Address SC warnings (most common: SC2155 - separate declare/assign)
   
4. **ci/prow/ci-operator-registry** - Registry loading errors
   - Often related to malformed metadata.json (invalid JSON, extra characters)
   - Use `jq .` to validate JSON syntax

**Complete validation workflow:**

```bash
# 1. Push changes
git push origin my-branch

# 2. Monitor validation (script handles the loop)
.claude/scripts/monitor-validation.sh 79996

# 3. If failures, analyze
if [[ $? -eq 1 ]]; then
  .claude/scripts/analyze-validation.sh 79996
  # Fix, commit, push, goto step 2
fi

# 4. When all pass, proceed to rehearsals
```

### 6. List Affected Jobs and Trigger Rehearsal

**ONLY trigger rehearsal AFTER validation passes.**

**Step 1: Identify affected jobs**

```bash
# List all jobs affected by your changes
.claude/scripts/list-affected-jobs.sh <PR>

# Filter for specific job type
.claude/scripts/list-affected-jobs.sh <PR> "azure-ipi-coco"
```

**IMPORTANT:** Job names often include version numbers (e.g., `candidate417`, `candidate421`).
Don't guess job names - always use `list-affected-jobs.sh` to get exact names.

**Step 2: Trigger rehearsals**

```bash
# Trigger specific job (use exact name from list)
.claude/scripts/trigger-rehearsal.sh <PR> <EXACT_JOB_NAME>

# Example:
.claude/scripts/trigger-rehearsal.sh 79996 "periodic-ci-openshift-sandboxed-containers-operator-devel-downstream-candidate421-aws-ipi-coco"
```

**OSC job name pattern:**
```
periodic-ci-openshift-sandboxed-containers-operator-<branch>-<version>-<platform>-<workload>
                                                              ^^^^^^^^
                                                              Version number - don't guess!
```

Examples of actual job names:
- `periodic-ci-openshift-sandboxed-containers-operator-devel-downstream-candidate421-aws-ipi-coco`
- `periodic-ci-openshift-sandboxed-containers-operator-devel-downstream-candidate420-azure-ipi-peerpods`
- `periodic-ci-openshift-sandboxed-containers-operator-devel-downstream-candidate-azure-ipi-kata`

### 7. Verify Rehearsal Started (CRITICAL - REQUIRED BEFORE MONITORING)

**AFTER triggering /pj-rehearse, you MUST verify the rehearsal actually started.**

Prow can reject rehearsals for several reasons:
- Job doesn't exist in the affected jobs list
- Job name typo or version mismatch
- Configuration errors preventing job generation
- Job not marked as rehearsable
- Job requires network-access label (restrict_network_access: false)

**MANDATORY verification script:**

```bash
# 1. Trigger rehearsal
.claude/scripts/trigger-rehearsal.sh <PR> <JOB_NAME>

# 2. Verify it started (checks every 2 min for 16 min)
.claude/scripts/verify-rehearsal-started.sh <PR> <JOB_PATTERN>
```

**Examples:**

```bash
# Example 1: After triggering candidate421 aws-ipi-coco
.claude/scripts/trigger-rehearsal.sh 80236 "periodic-ci-openshift-sandboxed-containers-operator-devel-downstream-candidate421-aws-ipi-coco"
.claude/scripts/verify-rehearsal-started.sh 80236 "candidate421.*aws-ipi-coco"

# Example 2: After triggering azure-ipi-kata
.claude/scripts/trigger-rehearsal.sh 79996 "periodic-ci-openshift-sandboxed-containers-operator-devel-downstream-candidate-azure-ipi-kata"
.claude/scripts/verify-rehearsal-started.sh 79996 "azure-ipi-kata"
```

**The script will:**
- Check every 2 minutes for rejection messages
- Check if job appears in PR checks
- Exit code 0: Job found (proceed to monitoring)
- Exit code 1: Rejected or failed to start (investigate)
- Exit code 2: Invalid arguments

**What this catches:**

1. **Rejection messages** - "job...either don't exist or were not found to be affected"
   - Happens within seconds of /pj-rehearse comment
   - Indicates job name mismatch or not in affected list
   
2. **Silent failures** - Job never appears in checks after 15 minutes
   - Prow processed the comment but didn't start the job
   - Configuration errors or infrastructure issues

**Example rejection message:**
```
@tbuskey: the following jobs were requested
but either don't exist or were not found to be affected by this PR, and cannot be rehearsed:
- periodic-ci-openshift-sandboxed-containers-operator-devel-downstream-candidate422-aws-ipi-coco
                                                                           ^^^
                                                                           Wrong version!
```

**ONLY proceed to monitoring AFTER this verification passes.**

### 8. Monitor Results

**For OSC steps (often long-running):**
```bash
.claude/scripts/monitor-rehearsal.sh <PR> <pattern> 3 300 <step-name> 120 true
```

Example for install-trustee-operator:
```bash
.claude/scripts/monitor-rehearsal.sh 79244 azure-ipi-coco 3 300 install-trustee-operator 120 true
```

This monitors the step completion, waits 120s for artifacts, then continues to full job completion.

### 9. Iteration

**DO NOT push** while a rehearsal cluster is running - it will abort the cluster immediately.

**Check for active rehearsals before pushing:**
```bash
.claude/scripts/prow-fetch.sh pr-checks <PR> <pattern>
```

Only push when status is: `success`, `failure`, `aborted`, or `error` (not `pending` or `triggered`).

## OSC-Specific Knowledge

### Trustee Operator (for CoCo tests)

**Version compatibility:**
- trustee 1.1.x → kbs-client v0.17.0
- trustee 1.11.x → kbs-client v0.19.0

**Components:**
- KBS (Key Broker Service) - provides secrets/resources to confidential workloads
- Attestation Service - validates TEE evidence
- RCA protocol - Resource-Centric Authorization

**Common issues:**
- CatalogSource not ready before Subscription
- kbs-client SSL certificate errors (use HTTP in test environments)
- Resource not found (check KbsConfig published secrets)

### OSC Operator

**CatalogSources:**
- `brew-catalog` - internal builds (Pre-GA tests)
- `redhat-operators` - GA releases

**Workload types:**
- `coco` - Confidential Containers (requires trustee)
- `kata` - Kata Containers
- `peerpods` - Peer Pods (remote VMs)

### Test Flow

1. **Pre phase:** Install operators (OSC, Trustee), configure cluster
2. **Test phase:** Run openshift-extended-test with OSC filters
3. **Post phase:** Collect must-gather, cleanup

## Common Error Patterns

**"CatalogSource not READY":**
```
Solution: Add wait loop after CatalogSource creation
```

**"Subscription has no InstallPlan reference":**
```
Solution: Check CatalogSource READY state, OLM resolution errors
```

**"kbs-client: Authenticating with KBS failed":**
```
Solution: Check Trustee URL, TLS certificates, kbsres1 resource exists
```

**"Pod not ready after 150s":**
```
Solution: Add polling loop with diagnostics, check pod events
```

**"404 Not Found" for resource:**
```
Solution: Verify KbsConfig includes the resource in kbsSecretResources
```

## Example Session

```bash
# 1. Identify failing job
/osc-step-debug azure-ipi-coco

# 2. Claude will:
#    - Find the failing step in step-registry/sandboxed-containers-operator/
#    - Analyze logs with prowjob-analyzer
#    - Identify the issue (e.g., CatalogSource not ready)
#    - Make the fix (add wait loop)
#    - Run make update
#    - Commit changes
#    - Trigger rehearsal
#    - Monitor until completion
#    - Report results

# 3. On success: Done
# 4. On failure: Iterate (Claude analyzes new error, fixes, repeats)
```

## Communication Protocol

**CRITICAL: Always announce phase transitions and provide clear status updates.**

The debugging workflow has distinct phases. The user must know what phase you're in and why:

### Phase Announcements

When entering each phase, announce it clearly:

```
🔍 **PR VALIDATION** - Checking if PR passes CI validation checks...
```

```
🐛 **DEBUGGING VALIDATION** - Fixing validation failures before rehearsal can start...
   Found 3 failing checks: owners, step-registry-metadata, step-registry-shellcheck
```

```
🚀 **TRIGGERING REHEARSAL** - Validation passed. Starting cluster creation...
```

```
👀 **MONITORING REHEARSAL** - Watching for install-trustee-operator step execution...
```

```
🔍 **ANALYZING FAILURE** - Step failed. Examining logs to identify root cause...
```

```
🔧 **FIXING ISSUE** - Applying fix for <issue description>...
```

### Progress Updates

Within each phase, provide progress updates:
- "Analyzing shellcheck failure..."
- "Creating missing OWNERS file..."
- "✅ Fixes applied. Validation checks re-running..."
- "Cluster creating (15 min estimated)..."
- "Step 'install-trustee-operator' is running..."
- "❌ Step failed: CatalogSource not READY"

### Context Switching

When switching focus, explain why:
- "Can't start rehearsal until validation passes - debugging validation issues first..."
- "Validation passed - proceeding to rehearsal..."
- "Step failed - switching to failure analysis mode..."

### Example Communication Flow

```
User: "Debug the install-trustee step"

Claude:
🔍 **PR VALIDATION** - Checking PR #79996 status...
   
   Found 3 failing validation checks:
   ❌ ci/prow/owners
   ❌ ci/prow/step-registry-metadata  
   ❌ ci/prow/step-registry-shellcheck
   
   Can't start rehearsal until these pass - debugging validation issues first...

🐛 **DEBUGGING VALIDATION** - Analyzing failures...
   
   Issue 1: Missing OWNERS file in install-trustee-operator/
   Issue 2: Shellcheck SC2155 warnings (3 instances)
   
   Fixing...
   ✅ Created OWNERS file
   ✅ Fixed shellcheck warnings by separating variable declarations
   
   Committing and pushing fixes...
   ✅ Validation checks re-running

⏳ **WAITING FOR VALIDATION** - Jobs pending (~2-3 min)...

✅ **VALIDATION PASSED** - All checks green

🚀 **TRIGGERING REHEARSAL** - Starting azure-ipi-coco job...
   Comment posted: /pj-rehearse periodic-ci-openshift-sandboxed-containers-operator-devel-downstream-candidate-azure-ipi-coco
   
   Rehearsal URL: https://prow.ci.openshift.org/...

👀 **MONITORING REHEARSAL** - Watching for install-trustee-operator step...
   Phase 1: Monitor step execution (+ 120s artifact wait)
   Phase 2: Continue to full job completion
   
   [1] Cluster creating (estimated 15-20 min)...
   [2] Pre-phase running...
   [3] Step 'install-trustee-operator' started...
   [4] Step completed ✅ (artifacts collected)
   
   Continuing to full job completion...
```

**Key principles:**
1. **Never work silently** - Always announce what phase you're in
2. **Explain context switches** - Tell the user why you're changing focus  
3. **Show progress** - Not just "done" but the steps along the way
4. **Use clear visual markers** - Emojis (🔍 🐛 🚀 👀 ✅ ❌) help users scan quickly
5. **Estimate timing** when possible - "~2-3 min", "estimated 15-20 min"
6. **ACTIVE MONITORING REQUIRED** - Never wait passively; always check status every 2-3 min

## Automation Level

**This skill operates autonomously for OSC step debugging:**
- Analyzes failures automatically
- Makes fixes based on known patterns
- Triggers rehearsals and monitors results
- Iterates on failures
- **WAITS for user input** after each iteration completes
- **ALWAYS announces phase transitions and progress**

**User confirmation required for:**
- Starting a new iteration after failure/success
- Making changes outside standard patterns
- Architectural decisions

## Notes

- All changes stay within sandboxed-containers-operator scope
- Follows OSC team coding patterns and conventions
- Uses OLM stage-by-stage polling for operator installations
- Strips ANSI color codes from logs for readability
- Maps operator versions to compatible client versions
