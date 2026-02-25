---
name: installer-add-test
description: Read an installer PR and create a CI presubmit test job locally
parameters:
  - name: input
    description: Either a PR URL (e.g., "https://github.com/openshift/installer/pull/12345") or a local directory path (e.g., "/path/to/installer")
    required: true
---

You are helping users create CI presubmit test jobs for the OpenShift installer repository based on Pull Request content or local changes.

## Context

The user wants to create a new presubmit test job for the OpenShift installer repository. They have provided either:
1. A PR URL that contains information about what feature or changes are being made
2. A local directory path where they have uncommitted or committed changes

Your task is to:

1. Detect whether the input is a PR URL or a local directory path
2. Fetch and analyze the content (from GitHub PR or local git changes)
3. Determine what kind of test is appropriate
4. Add the test configuration to the installer CI config file
5. Generate the downstream Prow job files

## Input Provided

**Input**: {{input}}

## Step 0: Detect Input Type and Gather Changes

First, determine what type of input was provided:

### If Input is a PR URL

Check if the input matches a GitHub PR URL pattern (contains "github.com" and "/pull/"):
- Extract the PR number from the URL
- Proceed to Step 1 (Fetch PR Information from the Internet)

### If Input is a Local Directory Path

If the input is a file path:

1. **Verify the directory exists** using bash:
   ```bash
   test -d "{{input}}" && echo "Directory exists" || echo "Directory not found"
   ```

2. **Check if it's a git repository**:
   ```bash
   cd "{{input}}" && git status
   ```

3. **Gather local changes** using git commands:
   ```bash
   cd "{{input}}"

   # Get uncommitted changes (staged and unstaged)
   git diff HEAD

   # Get list of changed files
   git diff --name-only HEAD

   # Get recent commits if no uncommitted changes
   git log -1 --stat

   # Get commit message for context
   git log -1 --pretty=format:"%s%n%b"
   ```

4. **Analyze the changes**:
   - Look at the diff output to understand what's being modified
   - Identify changed files and their paths
   - Extract any commit messages or PR references from git log
   - Determine the platform and feature from file paths and changes

5. **Skip to Step 2** (Analyze the Content) using the local git information instead of PR data

## Your Task

### 1. Fetch PR Information (If PR URL Provided)

**Only perform this step if the input is a PR URL. Skip to Step 2 if local directory.**

Use the WebFetch tool to fetch the PR details from GitHub:
- Extract the PR number from the URL
- Fetch the PR page using WebFetch
- Analyze the PR title, description, and file changes

Look for:
- PR title and description
- Changed files (visible in the "Files changed" tab)
- Any test requirements mentioned in the PR description
- Platform or feature being modified (AWS, GCP, Azure, vSphere, etc.)
- Related issues or design documents

### 2. Analyze the Changes

Based on the PR content (from GitHub) or local git changes (from directory), determine:
- **Platform**: Which cloud platform(s) are affected (aws, gcp, azure, vsphere, openstack, metal, etc.)
- **Test type**: What kind of test is needed:
  - e2e test (end-to-end)
  - Unit test
  - Integration test
  - Upgrade test
  - UPI (User Provisioned Infrastructure) test
  - Special configuration test (proxy, custom VPC, edge zones, etc.)
- **Test scope**: What should the test validate?
- **Existing patterns**: Look for similar tests in the config to follow the same pattern

### 3. Search for Existing Test Patterns

Before creating a new test, search for similar tests:
- Read the current installer config: `ci-operator/config/openshift/installer/openshift-installer-main.yaml`
- Look for similar tests for the same platform
- Identify the appropriate workflow or test steps to use
- Use `/step-finder` if needed to find existing step-registry components

For example:
- AWS tests often use: `openshift-e2e-aws` workflow
- Custom configurations might use custom pre/test/post chains
- Edge zones have specific workflows: `openshift-e2e-aws-edge-zones`
- Dual-stack networking: `openshift-e2e-aws-dualstack` workflow

### 4. Create a Dedicated Test Step

**ALWAYS create a dedicated test step in the step-registry** for the new test. This provides better reusability and maintainability.

#### 4.1 Design the Step

Create a new step with these files in `ci-operator/step-registry/`:
- `<org>-<component>-<action>-ref.yaml` - Step metadata
- `<org>-<component>-<action>-commands.sh` - Test script

**Step naming convention**: `installer-e2e-<platform>-<feature>`
Example: `installer-e2e-aws-local-zones`

#### 4.2 Create the Step Reference File

Create `ci-operator/step-registry/<org>/<component>/<action>/<org>-<component>-<action>-ref.yaml`:

```yaml
ref:
  as: <step-name>                        # e.g., installer-e2e-aws-local-zones
  from: tests                            # Base image to run test from
  commands: <step-name>-commands.sh      # Script file name
  resources:
    requests:
      cpu: 1000m
      memory: 2Gi
  documentation: |-
    <Brief description of what this test does>

    This test validates <feature> for <platform>.
```

#### 4.3 Create the Commands Script

Create `ci-operator/step-registry/<org>/<component>/<action>/<org>-<component>-<action>-commands.sh`:

```bash
#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Running <feature> test for <platform>"

# Add your test commands here
# Example:
# export TEST_SUITE=<test-suite-name>
# export TEST_ARGS="<test-specific-args>"
# make test
```

#### 4.4 Design the Test Configuration

Create a test configuration entry that uses your new dedicated step:

```yaml
- as: <test-name>                    # Unique test identifier (e.g., "e2e-aws-local-zones")
  run_if_changed: <file-pattern>      # Optional: only run if specific files changed (e.g., "aws")
  optional: true/false                # Optional: whether test is optional
  always_run: true/false              # Optional: whether to always run
  skip_if_only_changed: <pattern>     # Optional: skip if only these files changed
  steps:
    cluster_profile: <profile>        # Cloud credentials profile (e.g., aws-3, gcp, azure-2)
    env:                              # Environment variables
      KEY: value
    pre:                              # Pre steps (cluster setup)
    - chain: <pre-chain>              # Use existing setup chain (e.g., ipi-aws-pre)
    test:                             # Test phase - ALWAYS use your dedicated step
    - ref: <your-new-step-name>       # Reference your new step
    post:                             # Post steps (cleanup)
    - chain: <post-chain>             # Use existing cleanup chain (e.g., ipi-aws-post)
```

**Important Guidelines**:
- Test names should be descriptive: `e2e-<platform>-<feature>`
- Use `run_if_changed` to only trigger on relevant file changes
- Set `optional: true` for new/experimental tests
- Choose appropriate `cluster_profile` for the platform
- **ALWAYS create a dedicated step** in the test phase
- Reuse existing pre/post chains for cluster setup and cleanup
- Keep the test step focused on validating the specific feature

### 5. Create the Step Files

Before adding the test configuration, create the step files in the step-registry:

1. **Create the step directory structure**:
   - Determine the directory path: `ci-operator/step-registry/<org>/<component>/<action>/`
   - Example: `ci-operator/step-registry/installer/e2e/aws-local-zones/`

2. **Create the ref.yaml file**:
   - Use the Write tool to create: `ci-operator/step-registry/<path>/<step-name>-ref.yaml`
   - Include proper metadata (as, from, commands, resources, documentation)

3. **Create the commands.sh file**:
   - Use the Write tool to create: `ci-operator/step-registry/<path>/<step-name>-commands.sh`
   - Include proper bash script with shebang and error handling
   - Make sure it's executable (set permissions if needed)

4. **Create the OWNERS file (if creating a new directory)**:
   - If you created a new directory in the step-registry (for steps, workflows, chains, or refs), add an OWNERS file
   - Use the Write tool to create: `ci-operator/step-registry/<path>/OWNERS`
   - Include the installer team approvers and reviewers:
   ```yaml
   approvers:
   - barbacbd
   - jhixson74
   - patrickdillon
   - rna-afk
   - sadasu
   - tthvo
   reviewers:
   - barbacbd
   - jhixson74
   - patrickdillon
   - rna-afk
   - sadasu
   - tthvo
   ```

5. **Validate the step structure**:
   - Ensure file naming matches the pattern
   - Verify the YAML syntax is correct
   - Check that the commands.sh has proper bash conventions

### 6. Add the Test to the Config File

1. Read the current config file:
   ```
   ci-operator/config/openshift/installer/openshift-installer-main.yaml
   ```

2. Find the `tests:` section

3. Add your new test entry in the appropriate location:
   - Group with similar platform tests (all AWS tests together, etc.)
   - Maintain alphabetical order within the group if possible
   - Follow existing formatting and indentation
   - **Ensure the test references your new step** in the test phase

4. Use the Edit tool to add the test configuration

### 7. Validate and Generate

After creating the step files and adding the test:

1. **Validate the step registry**:
   ```bash
   make validate-step-registry
   ```
   This ensures your new step is properly structured.

2. **Run make update** to generate downstream artifacts:
   ```bash
   make update
   ```
   This will:
   - Update `zz_generated_metadata` in the config file
   - Generate Prow job configs in `ci-operator/jobs/openshift/installer/`
   - Validate the configuration

3. **Check for errors** in the output

4. **Show the changes**:
   ```bash
   git diff ci-operator/step-registry/
   git diff ci-operator/config/openshift/installer/openshift-installer-main.yaml
   git diff ci-operator/jobs/openshift/installer/openshift-installer-main-presubmits.yaml
   ```

### 8. Provide Summary

After completion, provide:
- **Test name**: The name of the new test
- **Platform**: Which platform it targets
- **Trigger**: When the test will run (always, on file changes, etc.)
- **Dedicated step created**: Name and location of the new step
- **Step files created**:
  - Step ref: `ci-operator/step-registry/<path>/<step-name>-ref.yaml`
  - Step commands: `ci-operator/step-registry/<path>/<step-name>-commands.sh`
- **Config files modified**:
  - Config file: `ci-operator/config/openshift/installer/openshift-installer-main.yaml`
  - Generated job file: `ci-operator/jobs/openshift/installer/openshift-installer-main-presubmits.yaml`
- **Next steps**: How to test and commit the changes

## Example Workflows

### Example 1: Using PR URL

**Input**: `https://github.com/openshift/installer/pull/8472`
**PR Title**: "Add support for AWS Local Zones in installer"

1. **Detect input type**: URL detected, proceed with WebFetch
2. **Fetch PR** using WebFetch: Extract PR number and fetch PR page
3. **Analysis** reveals:
   - Platform: AWS
   - Feature: Local Zones support
   - Files changed: `pkg/asset/installconfig/aws/*.go`, `data/data/aws/*.tf`
3. **Search** for similar tests: Find `e2e-aws-ovn-edge-zones` as a pattern for pre/post chains
4. **Create dedicated step files**:
   - Create `ci-operator/step-registry/installer/e2e/aws-local-zones/installer-e2e-aws-local-zones-ref.yaml`:
     ```yaml
     ref:
       as: installer-e2e-aws-local-zones
       from: tests
       commands: installer-e2e-aws-local-zones-commands.sh
       resources:
         requests:
           cpu: 1000m
           memory: 2Gi
       documentation: |-
         Runs e2e tests for AWS Local Zones support in the installer.
     ```
   - Create `ci-operator/step-registry/installer/e2e/aws-local-zones/installer-e2e-aws-local-zones-commands.sh`:
     ```bash
     #!/bin/bash
     set -o nounset
     set -o errexit
     set -o pipefail

     echo "Running AWS Local Zones e2e tests"
     export TEST_SUITE=openshift/conformance/parallel
     export AWS_LOCAL_ZONES_ENABLED="yes"
     make test
     ```
5. **Design test** configuration:
   ```yaml
   - as: e2e-aws-ovn-local-zones
     run_if_changed: aws
     optional: true
     steps:
       cluster_profile: aws-3
       env:
         AWS_LOCAL_ZONES_ENABLED: "yes"
       pre:
       - chain: ipi-aws-pre
       test:
       - ref: installer-e2e-aws-local-zones
       post:
       - chain: ipi-aws-post
   ```
6. **Add to config file** in the AWS tests section
7. **Run validation**: `make validate-step-registry`
8. **Run generation**: `make update`
9. **Verify** generated files
10. **Provide summary** to user with all created files

### Example 2: Using Local Directory

**Input**: `/home/user/go/src/github.com/openshift/installer`
**Local changes**: Modified AWS local zones support files

1. **Detect input type**: Directory path detected
2. **Verify directory**: Check directory exists and is a git repo
3. **Gather changes** using git:
   ```bash
   cd /home/user/go/src/github.com/openshift/installer
   git diff HEAD
   git diff --name-only HEAD
   ```
4. **Analysis** of git diff reveals:
   - Platform: AWS
   - Feature: Local Zones support
   - Files changed: `pkg/asset/installconfig/aws/zones.go`, `data/data/aws/zones.tf`
   - Commit message: "aws: add local zones support for installer"
5. **Search** for similar tests in the release repo
6. **Create dedicated step files** in the release repo (current working directory)
7. **Design and add test** configuration to installer CI config
8. **Run validation**: `make validate-step-registry`
9. **Run generation**: `make update`
10. **Verify** and show git diff
11. **Provide summary** with all created files

## Important Notes

- **Dedicated Steps**: ALWAYS create a dedicated step in the step-registry for the test phase
- **Step Files**: Create both `-ref.yaml` and `-commands.sh` files in the step-registry
- **Reuse Pre/Post**: Use existing pre and post chains for cluster setup and cleanup
- **Input Detection**: Always detect whether input is a URL or directory path first
- **WebFetch**: Use WebFetch to access the PR page from GitHub (only for PR URLs)
- **Local Git**: Use git commands to analyze local changes (only for directory paths)
- **API Access**: If WebFetch doesn't provide enough detail, you may need to ask the user for more information
- **Directory Validation**: Always verify directory exists and is a git repository before analyzing
- **Validation**: The test configuration MUST be valid YAML
- **Step Validation**: Run `make validate-step-registry` before `make update`
- **Resource constraints**: Consider resource requirements (some platforms have limited capacity)
- **Capabilities**: Some tests require special capabilities (e.g., `capabilities: [intranet]` for metal tests)
- **Test skips**: Include `TEST_SKIPS` if certain tests are known to fail
- **Cluster profiles**: Each platform has specific cluster profiles (aws-2, aws-3, aws-4, gcp, azure-2, etc.)
- **Generated files**: Never manually edit files in `ci-operator/jobs/` - they are auto-generated
- **Step naming**: Follow the convention `<org>-<component>-<action>` (e.g., `installer-e2e-aws-local-zones`)

## Error Handling

If you encounter errors:
- **Input detection fails**: Ask user to clarify if they meant to provide a PR URL or directory path
- **Directory not found**: Verify the path is correct and accessible
- **Not a git repository**: The directory must be a git repository with changes
- **No changes found**: Check for both uncommitted changes and recent commits
- **YAML syntax errors**: Fix indentation and formatting in both step files and config
- **Step validation fails**: Check that step files follow the correct naming convention and structure
- **Missing step reference**: Ensure the step name in the test config matches the step `as:` field in ref.yaml
- **Commands script errors**: Verify bash script has proper shebang and error handling
- **Make update fails**: Read the error message and fix the config or step files
- **Missing cluster profile**: Use a valid profile from existing tests
- **WebFetch issues**: Ask user for additional details about the PR
- **Step directory structure**: Ensure files are in correct path (e.g., `ci-operator/step-registry/org/component/action/`)

## Advanced Features

For complex tests, you may need:

**In the test configuration**:
- **Dependencies**: Specify image dependencies with `dependencies:`
- **Leases**: Request specific resources with `leases:`
- **Credentials**: Mount credentials with `credentials:`
- **Timeout**: Set custom timeout with `timeout:`
- **Observers**: Enable observers for monitoring with `observers:`

**In the step definition (ref.yaml)**:
- **Environment variables**: Define step-specific env vars in the `env:` section
- **Grace period**: Set `grace_period:` for cleanup operations
- **Best effort**: Use `best_effort: true` for non-critical steps
- **Optional on success**: Use `optional_on_success: true` for optional verification steps
- **From image**: Specify different base image with `from:` (defaults to `tests`)

## Summary

You will:
1. **Detect** if input is a PR URL or local directory
2. **Gather changes** from GitHub PR or local git repository
3. **Analyze** the changes to understand platform and feature
4. **Create** dedicated step-registry components
5. **Configure** the test in installer CI config
6. **Validate and generate** Prow jobs
7. **Show** all changes and provide summary

Now begin analyzing the input: {{input}}
