---
description: Debug CI job failures using /pj-rehearse iterative testing
args: "[job_name]"
allowed-tools: Read, Edit, Bash, Grep, Glob, AskUserQuestion
---

# PJ-Rehearse Debug - Iterative CI Job Debugging

Debug and fix CI job configuration issues using /pj-rehearse for rapid iteration.

**Arguments**: job_name={{job_name}} (optional - will search if not provided)

## Overview

This skill helps debug CI job failures by:
1. Identifying the failing job configuration
2. Making targeted fixes based on error analysis
3. Testing changes with /pj-rehearse
4. Iterating until the job passes

## Workflow

### 1. Initial Setup

If no branch exists for this work:
```bash
git checkout main && git pull && git checkout -b debug-{{job_name}}
```

### 2. Locate Configuration Files

Find the relevant files:
- **CI config**: `ci-operator/config/<org>/<repo>/*.yaml`
- **Step registry**: `ci-operator/step-registry/<component>/`
- **Generated jobs**: `ci-operator/jobs/<org>/<repo>/*.yaml` (auto-generated, don't edit directly)

### 3. Analyze the Failure

Common failure patterns:
- **Base image issues**: `from: cli` vs `from: tools` vs `from_image:` 
- **Network restrictions**: `restrict_network_access: true` blocks external downloads
- **Missing tools**: cli image has oc/kubectl, tools image has additional utilities
- **Environment variables**: Check defaults vs overrides in test config
- **Workflow chain order**: Ensure dependencies run before dependents

### 4. Make Fixes

Based on error analysis:
- **If "image not found" error**: Fix base image reference (use `from: cli` not `from_image: ... tag: latest`)
- **If "command not found" error**: Switch base image or install tool in script
- **If "network unreachable" error**: Either remove `restrict_network_access: true` or use pre-built image with required assets
- **If "variable not set" error**: Add environment variable to CI config or step ref

### 5. Generate and Commit

```bash
make update
git add ci-operator/config ci-operator/jobs ci-operator/step-registry
git commit -m "Fix {{job_name}}: <describe what you fixed>"
```

### 6. Create/Update PR

First time:
```bash
gh auth setup-git
git push -u origin debug-{{job_name}}
gh pr create --repo openshift/release --title "Fix {{job_name}}" --body "Fixes:\n- <list changes>"
```

Updates:
```bash
git push
```

### 7. Wait for Rehearsal Notification

Poll for REHEARSALNOTIFIER comment on the PR:
```bash
gh pr view <PR_NUMBER> --repo openshift/release --json comments --jq '.comments[] | select(.author.login == "openshift-ci-robot") | select(.body | contains("REHEARSALNOTIFIER")) | .body'
```

Extract the rehearsable job name from the table in the comment.

### 8. Trigger Rehearsal

Post comment on PR:
```bash
gh pr comment <PR_NUMBER> --repo openshift/release --body "/pj-rehearse <job-name>"
```

### 9. Monitor Results

**For quick jobs (< 30 minutes):**
```bash
gh pr checks <PR_NUMBER> --repo openshift/release
```

**For long-running jobs (> 30 minutes):**

Set up a background monitor (checks every 5 minutes for up to 3 hours):

```bash
cat > /tmp/monitor_rehearsal.sh << 'MONITOR_EOF'
#!/bin/bash
set -euo pipefail

PR_NUM=<PR_NUMBER>
JOB_NAME="<short-job-name>"  # e.g., "azure-ipi-coco"
END_TIME=$(($(date +%s) + 10800))  # 3 hours
CHECK_INTERVAL=300  # 5 minutes

echo "=== Rehearsal Monitoring Started ==="
echo "PR: https://github.com/openshift/release/pull/${PR_NUM}"
echo "Job: ci/rehearse/periodic-ci-openshift-sandboxed-containers-operator-devel-downstream-candidate-${JOB_NAME}"
echo "Monitoring for 3 hours (until $(date -d @${END_TIME} '+%Y-%m-%d %H:%M:%S'))"
echo ""

iteration=1
while true; do
    current_time=$(date +%s)
    
    if [ ${current_time} -ge ${END_TIME} ]; then
        echo "=== 3 Hour Monitoring Completed ==="
        final_status=$(gh pr checks ${PR_NUM} --repo openshift/release 2>&1 | grep "${JOB_NAME}" || echo "Status unavailable")
        echo "Final Status: ${final_status}"
        exit 0
    fi
    
    status_line=$(gh pr checks ${PR_NUM} --repo openshift/release 2>&1 | grep "${JOB_NAME}" || echo "")
    
    if [ -n "${status_line}" ]; then
        job_status=$(echo "${status_line}" | awk '{print $2}')
        elapsed_mins=$(( (current_time - (END_TIME - 10800)) / 60 ))
        
        echo "[${iteration}] $(date '+%H:%M:%S') (${elapsed_mins}m) - Status: ${job_status}"
        
        if echo "${job_status}" | grep -qE "^(pass|fail)$"; then
            echo ""
            echo "=== Job Completed: ${job_status} ==="
            prow_url=$(echo "${status_line}" | awk '{print $4}')
            echo "Prow Logs: ${prow_url}"
            
            if [ "${job_status}" = "pass" ]; then
                echo "✓ SUCCESS: Test passed"
            else
                echo "✗ FAILURE: Check logs for error details"
            fi
            exit 0
        fi
    fi
    
    iteration=$((iteration + 1))
    sleep ${CHECK_INTERVAL}
done
MONITOR_EOF
chmod +x /tmp/monitor_rehearsal.sh
/tmp/monitor_rehearsal.sh &
```

This runs in the background and reports when the job completes or after 3 hours.

**View logs if failed:**
- Click through to Prow job URL in PR checks
- Or use: `gh pr view <PR_NUMBER> --repo openshift/release --json statusCheckRollup`
- Download build logs: `curl -sL "<prow-gcs-url>/build-log.txt" | tail -500`

### 10. Iterate

If rehearsal fails:
1. Analyze new errors
2. Make additional fixes
3. Run `make update`
4. Commit and push
5. Wait for new REHEARSALNOTIFIER
6. Trigger `/pj-rehearse` again

Repeat until the job passes.

## Common Debugging Patterns

### Network Restrictions Issue

**Symptom**: Script fails to download files when `restrict_network_access: true`

**Error examples**:
```
curl: (6) Could not resolve host
fatal: unable to access 'https://github.com/...': Could not resolve host
```

**Solutions**:
- Remove `restrict_network_access: true` if network is required for installation
- Note: Rehearsals will require `network-access-rehearsals-ok` label from org member
- Alternative: Pre-render manifests or vendor dependencies to avoid runtime downloads

### Missing Command/Tool in Container

**Symptom**: `command not found` errors in step execution

**Error examples**:
```
bash: git: command not found
bash: jq: command not found
bash: python3: command not found
```

**Diagnosis**:
```bash
# Check what's in each base image:
# cli: oc, kubectl (minimal)
# tools: git, make, go, python, jq, and build tools
# tests-private: openshift-tests and dependencies
```

**Solutions**:
- **`from: cli`**: Only oc/kubectl - use for simple cluster operations
- **`from: tools`**: Git, make, compilers - use for building/installing
- **`from: tests-private`**: Test execution - use for running test suites
- **Install in script**: Add installation steps if tool is small (e.g., `curl -o /tmp/tool`)
- **Custom base image**: Define in `base_images:` if you need specific tooling

### Base Image Selection Decision Tree

1. **Need git, make, go, python?** → `from: tools`
2. **Only need oc/kubectl?** → `from: cli`
3. **Running openshift-tests?** → `from: tests-private`
4. **Need specific version of a tool?** → Define custom `base_images:` entry

### Environment Variable Issues

**Where to set them**:
- Step defaults: In `*-ref.yaml` under `env:`
- Job overrides: In CI config under `tests: - steps: env:`
- Shared/generated: Via separate env-cm or config step

## Tips

- Always run `make update` after editing configs
- Check generated job files to verify changes
- Use `/test <job-name>` to run full job after rehearsal passes
- Search for similar working jobs as reference patterns
- Read error logs carefully - they often contain the exact fix needed

### Analyzing Prow Build Logs

**Finding the failure**:
```bash
# Get last 200 lines (usually contains the error)
curl -sL "<prow-gcs-url>/build-log.txt" | tail -200

# Search for specific step
curl -sL "<prow-gcs-url>/build-log.txt" | grep -A 100 "Running step <step-name>"

# Find error messages
curl -sL "<prow-gcs-url>/build-log.txt" | grep -i "error\|failed\|command not found"
```

**Common error patterns**:
- `command not found` → Wrong base image (need tools instead of cli)
- `Could not resolve host` → Network restrictions blocking access
- `image not found` → Invalid base image reference
- `No such file or directory` → Path issue or missing SHARED_DIR file
- `exit status 1` → Check preceding lines for actual error

### Iterative Debugging Workflow

1. **First rehearsal failure** → Identify error in build-log.txt
2. **Fix the issue** → Edit config/step files
3. **Commit and push** → Update PR
4. **Wait for new REHEARSALNOTIFIER** → Bot updates rehearsable jobs list
5. **Trigger new rehearsal** → `/pj-rehearse <job-name>`
6. **Monitor progress** → Use background monitor for long jobs
7. **Repeat until pass** → Each iteration fixes one issue

### Multiple Issues in One Job

Jobs may fail for multiple reasons - fix them one at a time:

**Example from this session**:
- Issue 1: Network blocked → Fixed: `restrict_network_access: false`
- Issue 2: Git missing → Fixed: `from: tools` instead of `from: cli`

After each fix, re-run rehearsal to discover the next issue.

## Output

Report:
- Configuration files changed
- Fixes applied
- PR URL
- Rehearsal job name
- Current rehearsal status
