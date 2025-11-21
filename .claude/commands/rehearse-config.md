---
name: rehearse-config
description: Add hypershift debug ref to a test config, create PR, and trigger rehearsal
parameters:
  - name: config_name
    description: The config name string to search for in the test configuration
    required: true
  - name: release
    description: The release version string (e.g., "4.18") that the file name should contain
    required: true
---

You are helping automate the process of adding a hypershift debug reference to an OpenShift test configuration and rehearsing the changes.

## Task Overview

Add the cucushift-hypershift-extended-debug reference to a test configuration and trigger CI rehearsal.

## Parameters
- **Config name**: {{config_name}}
- **Release**: {{release}}

## Step-by-Step Instructions

Execute the following steps in order:

### 1. Git Pull
Pull the latest changes from the repository:
```bash
git pull
```

### 2. Create New Branch
Create and checkout a new branch named after the config:
```bash
git checkout -b {{config_name}}
```

### 3. Find the Target File
Search for the configuration file in `ci-operator/config/openshift/openshift-tests-private/` that:
- Contains the config name string: `{{config_name}}`
- File name contains the release string: `{{release}}`
- File name does NOT contain: `upgrade`

Use grep or glob to find the matching file.

### 4. Locate the Code Block
In the target file, find the code block that starts with a line containing: `{{config_name}}`

This should be a test definition block in the YAML configuration.

### 5. Add the Debug Reference
Under the line containing `-chain` within that code block, add a new line:
```yaml
    - ref: cucushift-hypershift-extended-debug
```

**Important**:
- Match the indentation of the surrounding lines (typically 4 spaces)
- Add it immediately after the `-chain` line
- Preserve YAML formatting

### 6. Commit and Push
Commit the change and push to the remote branch:
```bash
git add .
git commit -m "{{config_name}}"
git push -u origin {{config_name}}
```

### 7. Create Pull Request
Submit a pull request to https://github.com/openshift/release using the `gh` CLI:
```bash
gh pr create --title "{{config_name}}" --body "Add cucushift-hypershift-extended-debug ref to {{config_name}}"
```

Save the PR URL for reference.

### 8. Wait for CI Robot Comment
Monitor the PR for a comment from `openshift-ci-robot` that starts with `[REHEARSALNOTIFIER]`.

Use the GitHub CLI to check for new comments:
```bash
gh pr view <pr-number> --comments
```

You may need to wait and poll periodically. Check every 30-60 seconds until the comment appears.

### 9. Parse the Test Name
From the REHEARSALNOTIFIER comment, locate the table and extract the string from the 'Test name' row.

The comment will contain a markdown table. Find the row with "Test name" and extract the test name value.

### 10. Add Rehearsal Comment
Post a comment on the PR to trigger rehearsal:
```bash
gh pr comment <pr-number> --body "/pj-rehearse <test-name>"
```

Where `<test-name>` is the value extracted from step 9.

## Error Handling

- If no matching file is found, report the search criteria and ask the user to verify the config_name and release parameters
- If multiple files match, list them and ask the user which one to modify
- If the config block is not found, show the file contents and ask for clarification
- If the `-chain` line is not found in the config block, report this and ask for guidance
- If the PR creation fails, check if a PR already exists for this branch
- If the CI robot comment doesn't appear within a reasonable time (5-10 minutes), inform the user and provide the PR URL for manual monitoring

## Verification

After completing all steps:
1. Confirm the PR was created successfully
2. Confirm the REHEARSALNOTIFIER comment was found
3. Confirm the rehearsal comment was posted
4. Provide the PR URL and test name to the user

## Example Flow

For `config_name="aws-ipi-ovn-hypershift-mce"` and `release="4.18"`:

1. `git pull` → Update local repo
2. `git checkout -b aws-ipi-ovn-hypershift-mce` → Create branch
3. Find file: `ci-operator/config/openshift/openshift-tests-private/openshift-openshift-tests-private-release-4.18.yaml`
4. Locate the test block starting with `aws-ipi-ovn-hypershift-mce`
5. Add `    - ref: cucushift-hypershift-extended-debug` after the `-chain` line
6. Commit and push with message "aws-ipi-ovn-hypershift-mce"
7. Create PR with title "aws-ipi-ovn-hypershift-mce"
8. Wait for `openshift-ci-robot` comment starting with `[REHEARSALNOTIFIER]`
9. Extract test name from the table (e.g., `pull-ci-openshift-openshift-tests-private-release-4.18-aws-ipi-ovn-hypershift-mce`)
10. Comment `/pj-rehearse pull-ci-openshift-openshift-tests-private-release-4.18-aws-ipi-ovn-hypershift-mce`

Now execute these steps for the provided parameters.
