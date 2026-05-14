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

Check job status:
```bash
gh pr checks <PR_NUMBER> --repo openshift/release
```

View logs if failed:
- Click through to Prow job URL in PR checks
- Or use: `gh pr view <PR_NUMBER> --repo openshift/release --json statusCheckRollup`

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

**Solutions**:
- Use a base image with pre-installed tools
- Change `from: cli` to `from: tools` if tools are available there
- Remove `restrict_network_access: true` if network is required
- Pre-render manifests instead of downloading at runtime

### Base Image Selection

- **`from: cli`**: Use for steps needing oc/kubectl only
- **`from: tools`**: Use for steps needing additional utilities
- **`from: tests-private`**: Use for test execution steps
- **Custom**: Define custom image in `base_images:` if needed

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

## Output

Report:
- Configuration files changed
- Fixes applied
- PR URL
- Rehearsal job name
- Current rehearsal status
