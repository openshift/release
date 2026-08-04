---
name: rhdh-decommission-release
description: >-
  Use when decommissioning an end-of-life RHDH release branch by removing CI
  config, generated Prow jobs, and branch protection from the openshift/release
  repository
allowed-tools: Read, Edit, Bash(ls ci-operator/config/redhat-developer/rhdh/redhat-developer-rhdh-release-*), Bash(find ci-operator/config/redhat-developer/rhdh -name 'redhat-developer-rhdh-release-*'), Bash(rm ci-operator/config/redhat-developer/rhdh/redhat-developer-rhdh-release-*), Bash(rm ci-operator/jobs/redhat-developer/rhdh/redhat-developer-rhdh-release-*), AskUserQuestion
---
# Decommission RHDH Release Branch Jobs

You are helping the user decommission CI jobs for an end-of-life RHDH (Red Hat Developer Hub) release branch.

## What This Command Does

Decommissioning removes all CI configuration for a given RHDH release branch. This is done when a release reaches end-of-life and no longer needs CI jobs running. Based on the pattern from PR #71895.

## Steps to follow:

1. **Get the release version**:
   - If the user provided a version (e.g., "1.7", "1.8"), use it directly
   - If no version was provided, ask the user for the RHDH release version to decommission
   - List existing release configs to help the user choose:
     - `ls ci-operator/config/redhat-developer/rhdh/redhat-developer-rhdh-release-*.yaml`

2. **Verify the files to be removed**:
   Show the user what will be deleted and ask for confirmation:

   - **CI config file**: `ci-operator/config/redhat-developer/rhdh/redhat-developer-rhdh-release-{version}.yaml`
   - **Generated job files**: `ci-operator/jobs/redhat-developer/rhdh/redhat-developer-rhdh-release-{version}-*.yaml` (typically `-presubmits.yaml` and `-periodics.yaml`)
   - **Branch protection entry**: The `release-{version}:` block in `core-services/prow/02_config/redhat-developer/rhdh/_prowconfig.yaml`

   If the CI config file does not exist, warn the user that this release may have already been decommissioned and ask if they want to continue checking for leftover files.

3. **Delete the CI config file**:
   Remove `ci-operator/config/redhat-developer/rhdh/redhat-developer-rhdh-release-{version}.yaml`

4. **Delete the generated job files**:
   Remove all matching files: `ci-operator/jobs/redhat-developer/rhdh/redhat-developer-rhdh-release-{version}-*.yaml`

5. **Remove branch protection configuration**:
   Edit `core-services/prow/02_config/redhat-developer/rhdh/_prowconfig.yaml` to remove the entire `release-{version}:` block under `branch-protection.orgs.redhat-developer.repos.rhdh.branches`.

   The block to remove looks like:
   ```yaml
               release-{version}:
                 allow_deletions: false
                 allow_force_pushes: false
                 enforce_admins: true
                 protect: true
                 required_status_checks:
                   contexts:
                   - <context1>
                   - <context2>
                   - <context3>
   ```

   Be careful to:
   - Only remove the block for the specified version
   - Preserve indentation and formatting of surrounding blocks
   - Not leave blank lines where the block was removed

6. **Confirm completion**: Summarize what was removed:
   - List deleted files
   - Confirm branch protection entry was removed
   - Remind the user to commit the changes and create a PR

## Important Notes

- **Do NOT run `make update`** -- since we are only deleting files and removing branch protection, there is nothing to regenerate
- The generated job files in `ci-operator/jobs/` are normally auto-generated, but when decommissioning we simply delete them along with the source config
- Always verify the files exist before attempting deletion
- This operation is destructive -- always confirm with the user before proceeding
