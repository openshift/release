---
description: Debug CI job failures using /pj-rehearse iterative testing
args: "[job_name] [org] [repo]"
allowed-tools: Read, Edit, Bash, Grep, Glob, AskUserQuestion
---

# PJ-Rehearse Debug - Iterative CI Job Debugging

Debug and fix CI job configuration issues using /pj-rehearse for rapid iteration.

**Arguments**: 
- `job_name` (optional): Specific job to debug (e.g., "azure-ipi-coco")
- `org` (optional): GitHub organization (default: "openshift")
- `repo` (optional): Repository name (will search if not provided)

## Overview

This skill provides a systematic workflow for debugging CI job failures in the openshift/release repository:

1. **Identify** the failing job configuration and related files
2. **Analyze** error patterns in Prow build logs
3. **Fix** issues based on common patterns (base images, network access, environment variables)
4. **Test** changes using /pj-rehearse
5. **Monitor** long-running rehearsals with background scripts
6. **Iterate** until the job passes

**Use cases:**
- New step-registry components failing in rehearsals
- Configuration changes causing unexpected failures
- Base image or tool availability issues
- Network restriction debugging
- Environment variable and secret issues

## Workflow

### 1. Initial Setup

If no branch exists for this work:
```bash
git checkout main && git pull && git checkout -b debug-<job-name>
```

Replace `<job-name>` with a descriptive name for the issue you're debugging.

### 2. Locate Configuration Files

Find the relevant files for your job:

**CI configuration** (source of truth - edit these):
```bash
# Find config file
find ci-operator/config/<org>/<repo> -name "*.yaml" | grep -v "__periodics"

# Example: ci-operator/config/openshift/my-repo/openshift-my-repo-main.yaml
```

**Step registry** (reusable test components):
```bash
# Find step definitions
find ci-operator/step-registry -name "*<step-name>*"

# Example: ci-operator/step-registry/my-component/install/
#   - my-component-install-ref.yaml (metadata)
#   - my-component-install-commands.sh (script)
```

**Generated jobs** (auto-generated - don't edit):
```bash
# View generated jobs (for reference only)
find ci-operator/jobs/<org>/<repo> -name "*.yaml"
```

### 3. Analyze the Failure

Common failure patterns:
- **Base image issues**: `from: cli` vs `from: tools` vs `from_image:` 
- **Network restrictions**: `restrict_network_access: true` blocks external downloads
- **Missing tools**: cli image has oc/kubectl, tools image has additional utilities
- **Environment variables**: Check defaults vs overrides in test config
- **Workflow chain order**: Ensure dependencies run before dependents

### 4. Make Fixes

Apply fixes based on error analysis (see Common Debugging Patterns below):

**Base image issues:**
```yaml
# Wrong - uses non-existent tag
from_image:
  namespace: ocp
  name: cli
  tag: latest

# Right - references base_images definition
from: cli
```

**Missing commands:**
```yaml
# If you need git, make, go, python:
from: tools

# If you only need oc/kubectl:
from: cli
```

**Network restrictions:**
```yaml
# Allow network access (requires network-access-rehearsals-ok label)
restrict_network_access: false
```

**Environment variables:**
```yaml
# In step ref:
env:
  - name: MY_VAR
    default: "default_value"
    
# In CI config test:
env:
  MY_VAR: "override_value"
```

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

Use the standardized monitor script:

```bash
# Monitor full job completion (default)
.claude/scripts/monitor-rehearsal.sh <PR_NUMBER> <SHORT_JOB_NAME>

# Examples:
# Full job completion
.claude/scripts/monitor-rehearsal.sh 79244 azure-ipi-coco

# Two-phase: Monitor step, then full job (RECOMMENDED for debugging)
.claude/scripts/monitor-rehearsal.sh 79244 azure-ipi-coco 3 300 "install-trustee-operator" 120 true

# Monitor step only (exits when step succeeds)
.claude/scripts/monitor-rehearsal.sh 79244 azure-ipi-coco 3 300 "install-trustee-operator" 120 false

# Run in background
.claude/scripts/monitor-rehearsal.sh 79244 aws-ipi-coco &

# Parameters:
#   PR_NUMBER: GitHub PR number (required)
#   SHORT_JOB_NAME: Part of job name to grep (e.g., "azure-ipi-coco") (required)
#   DURATION_HOURS: Monitoring duration in hours (default: 3)
#   CHECK_INTERVAL: Seconds between checks (default: 300 = 5 minutes)
#   STEP_NAME: Optional - monitor specific step (e.g., "install-trustee-operator")
#   ARTIFACT_WAIT: Seconds to wait after step success for artifacts (default: 60)
#   CONTINUE_AFTER_STEP: Continue to full job after step succeeds (default: true)
```

**What the monitor does:**
- **Default**: Waits for full job completion (pass or fail)
- **Two-phase mode** (RECOMMENDED): Validates step, then continues to full job
  - Phase 1: Monitors step completion + artifact wait
  - Phase 2: Continues to full job completion
  - Reports both step success and final job results
- **Step-only mode**: Exits when step succeeds (CONTINUE_AFTER_STEP=false)
- Checks status every 5 minutes (configurable)
- Auto-detects completion and reports Prow URL
- Times out after 3 hours (configurable)
- Can run in foreground or background (&)

**When to use two-phase monitoring:**
- **Debugging installation steps** (e.g., trustee operator)
  - Validates installation succeeds (Phase 1)
  - Validates integration works (Phase 2: INITDATA, TRUSTEE_URL, tests)
- Want faster feedback when step completes, but need full results
- Debugging configuration integration issues

**When to use step-only mode:**
- Only care about step validation, not full test results
- Need immediate feedback to iterate on step fixes quickly

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
- Use `.claude/scripts/monitor-rehearsal.sh` for long-running jobs
- Run monitors in background with `&` to continue working
- Use GCS browser URLs to check artifacts and step logs directly with curl
- Wait for running rehearsals to complete before pushing new commits (avoid aborting active tests)

### Accessing Prow Logs and Artifacts

**URLs you can freely access**:

Prow provides two URL patterns for accessing build logs and artifacts:

1. **Prow viewer** (web interface):
   ```
   https://prow.ci.openshift.org/view/gs/test-platform-results/pr-logs/pull/openshift_release/<PR>/<JOB_NAME>/<JOB_ID>/
   ```

2. **GCS browser** (direct artifact access):
   ```
   https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/test-platform-results/pr-logs/pull/openshift_release/<PR>/<JOB_NAME>/<JOB_ID>/
   ```

Both URLs provide access to:
- `build-log.txt` - Full job execution log
- `artifacts/` - Step-specific logs and output files
- `started.json` - Job start time and commit info
- `finished.json` - Job completion status and result
- `prowjob.json` - Full Prow job definition and status

**Example URLs**:
```bash
# Build log
https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/test-platform-results/pr-logs/pull/openshift_release/79244/rehearse-79244-periodic-ci-openshift-sandboxed-containers-operator-devel-downstream-candidate-azure-ipi-coco/2055345638224171008/build-log.txt

# Job artifacts directory
https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/test-platform-results/pr-logs/pull/openshift_release/79244/rehearse-79244-periodic-ci-openshift-sandboxed-containers-operator-devel-downstream-candidate-azure-ipi-coco/2055345638224171008/artifacts/azure-ipi-coco/

# Specific step logs
https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/test-platform-results/pr-logs/pull/openshift_release/79244/rehearse-79244-periodic-ci-openshift-sandboxed-containers-operator-devel-downstream-candidate-azure-ipi-coco/2055345638224171008/artifacts/azure-ipi-coco/sandboxed-containers-operator-install-trustee-operator/build-log.txt
```

### Analyzing Prow Build Logs

**Finding the failure**:
```bash
# Get last 200 lines (usually contains the error)
curl -sS "<gcs-url>/build-log.txt" | tail -200

# Search for specific step
curl -sS "<gcs-url>/build-log.txt" | grep -A 100 "Running step <step-name>"

# Find error messages
curl -sS "<gcs-url>/build-log.txt" | grep -i "error\|failed\|command not found"

# Check if a specific step ran
curl -sS "<gcs-url>/artifacts/azure-ipi-coco/" | grep -o "install-trustee-operator"

# Get step-specific logs
curl -sS "<gcs-url>/artifacts/azure-ipi-coco/<step-name>/build-log.txt" | tail -100
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

**Example scenario**:
- **Iteration 1**: Network blocked → Fix: `restrict_network_access: false` → Retest
- **Iteration 2**: Git missing → Fix: `from: tools` instead of `from: cli` → Retest
- **Iteration 3**: Missing env var → Fix: Add to step env → Retest
- **Iteration 4**: All pass! → Ready to merge

After each fix, re-run rehearsal to discover the next issue.

## Example Debugging Session

**Scenario**: New installation step failing in rehearsal

1. **Initial failure**: "command not found: git"
   - **Analysis**: Script tries to `git clone` but git not available
   - **Root cause**: Using `from: cli` (only has oc/kubectl)
   - **Fix**: Change to `from: tools` (includes git)

2. **After fix**: "Could not resolve host: github.com"
   - **Analysis**: Network request blocked
   - **Root cause**: Test has `restrict_network_access: true`
   - **Fix**: Change to `restrict_network_access: false`
   - **Note**: Rehearsal needs `network-access-rehearsals-ok` label

3. **Success**: Installation completes, test passes

This demonstrates the iterative process: each rehearsal reveals the next issue.

## Output

Report:
- Configuration files changed
- Fixes applied
- PR URL
- Rehearsal job name
- Current rehearsal status
