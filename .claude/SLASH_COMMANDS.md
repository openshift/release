# OpenShift Release Repository - Claude Code Slash Commands

## Overview

This document describes custom slash commands available for the OpenShift release repository to improve developer productivity when working with CI configurations.

## Installation

Slash commands are located in `.claude/commands/` directory. They are automatically available when using Claude Code.

## Available Commands

### `/step-finder` - Step Registry Component Discovery

**Purpose**: Search and discover existing step-registry steps, workflows, and chains to reuse in CI configurations.

**Why it exists**: The step-registry contains over 4,400 reusable CI components. This command helps developers find the right component instead of creating duplicates, saving time and ensuring consistency.

#### Basic Usage

```bash
/step-finder <search_query>
```

#### Advanced Usage

```bash
# Full syntax
/step-finder <search_query> [component_type] [show_usage] [show_reverse_deps]

# Examples:
/step-finder aws upgrade                         # Find all AWS upgrade components
/step-finder aws upgrade workflow                # Only workflows
/step-finder aws upgrade workflow yes            # Workflows + real usage examples
/step-finder install operator step yes yes       # Steps + usage + reverse deps
/step-finder openshift-e2e-test all no yes       # Show reverse deps only
/step-finder ipi-aws-pre all no no               # Disable reverse deps for speed
```

#### Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `search_query` | Yes | - | Keywords to search (platform, action, component) |
| `component_type` | No | all | Filter by: `step`, `workflow`, `chain`, or `all` |
| `show_usage` | No | no | Show real CI config usage examples: `yes` or `no` |
| `show_reverse_deps` | No | yes | Show reverse dependencies (what uses this): `yes` or `no` |

#### Search Query Examples

**By Platform**:
- `/step-finder aws e2e`
- `/step-finder vsphere disconnected`
- `/step-finder gcp upgrade`

**By Action**:
- `/step-finder install operator`
- `/step-finder upgrade cluster`
- `/step-finder must-gather`

**By Feature**:
- `/step-finder fips`
- `/step-finder ipv6`
- `/step-finder ovn metallb`

**Combined**:
- `/step-finder aws e2e upgrade serial`
- `/step-finder metal fips disconnected`

#### What It Returns

For each matching component:

1. **Component name and type** (step/workflow/chain)
2. **File location** - Full path to examine
3. **Description** - From documentation field
4. **Usage example** - How to reference in ci-operator config
5. **Environment variables** - Configurable parameters
6. **Dependencies** - Required components, credentials, images (what this uses)
7. **Reverse Dependencies** (default: enabled) - Which workflows/chains use this component
8. **Impact Assessment** - Risk level: HIGH/MEDIUM/LOW/NONE based on usage count
9. **Status** - Active maintenance, deprecation warnings
10. **(Optional) Real usage** - Actual configs using the component
11. **(Optional) Popularity** - How many repositories use it
12. **Related components** - Alternatives and complementary components

#### Features

##### 1. Component Type Filtering

Find only specific types of components:

```bash
# Only find workflows (not steps or chains)
/step-finder aws upgrade workflow

# Only find atomic steps
/step-finder e2e test step

# Find chains only
/step-finder install chain
```

##### 2. Real Usage Examples

See which repositories actually use the component:

```bash
/step-finder aws upgrade all yes
```

Returns:
- Count of CI configs using the component (popularity metric)
- 2-3 actual config file paths as examples
- Helps understand practical applications

##### 3. Dependency Visualization

For workflows and chains, see the complete dependency tree:
- What steps does it reference?
- What chains does it use?
- What credentials are required?
- Full pre → test → post structure

##### 4. Reverse Dependencies (NEW!)

**Enabled by default** - Shows which workflows/chains use a component and assesses impact:

```bash
/step-finder openshift-e2e-test
```

Returns:
- **Count** of workflows/chains that reference this component
- **List** of up to 10 components that use it (with "... and N more" for extensive usage)
- **Impact level** with visual indicator:
  - 🔴 **HIGH** (100+ uses): Core infrastructure, changes need extensive testing
  - 🟡 **MEDIUM** (10-99 uses): Widely used, thorough testing required
  - 🟢 **LOW** (1-9 uses): Limited usage, standard testing sufficient
  - ℹ️ **NONE** (0 uses): Top-level workflow or potentially unused

**Why it's useful**:
- **Understand blast radius**: See how many components would be affected by changes
- **Assess risk**: Know whether a change is low-risk or requires coordination
- **Find usage patterns**: Learn how others use the component
- **Identify orphans**: Find unused components that might be safe to remove
- **Plan testing**: Prioritize testing based on number of dependents

**How it works**:
- For **steps**: Searches all workflow/chain files for `- ref: <step-name>`
- For **chains**: Searches all workflow/chain files for `- chain: <chain-name>`
- For **workflows**: Searches ci-operator configs for `workflow: <workflow-name>`

**Disable for speed** (if you only want basic info):
```bash
/step-finder aws upgrade all no no
```

##### 5. Deprecation Detection

Automatically warns about:
- Components marked as "deprecated" or "legacy"
- Components not modified in over 12 months (potentially stale)
- Suggested replacements if mentioned in documentation

##### 6. Related Components

Suggests:
- Similar components in the same directory
- Alternative implementations
- Commonly used combinations

##### 7. Maintenance Status

Shows:
- Last modification date
- Whether component is actively maintained
- Git history context

### `/installer-add-test` - Installer PR Test Job Creator

**Purpose**: Analyze an OpenShift installer PR from GitHub or local changes and automatically create a corresponding CI presubmit test job with dedicated step-registry components.

**Why it exists**: Creating test jobs for installer PRs requires understanding the changes, choosing appropriate test workflows, creating dedicated test steps, and configuring the CI system correctly. This command automates the entire process by fetching PR details or analyzing local git changes, creating step-registry components, and generating CI configuration.

#### Basic Usage

```bash
# Using a GitHub PR URL
/installer-add-test https://github.com/openshift/installer/pull/12345

# Using a local directory path
/installer-add-test /path/to/installer
```

#### Parameters

| Parameter | Required | Description | Examples |
|-----------|----------|-------------|----------|
| `input` | Yes | Either a PR URL or local directory path | `https://github.com/openshift/installer/pull/12345` or `/home/user/go/src/github.com/openshift/installer` |

#### What It Does

The command performs a complete end-to-end workflow:

**1. Detects input type** (PR URL vs local directory)
   - Checks if input contains "github.com/pull/"
   - Validates directory exists if local path

**2. Gathers changes** from the appropriate source:
   - **PR URL**: Fetches PR information from GitHub using WebFetch
   - **Local directory**: Uses git commands to analyze changes
     ```bash
     git diff HEAD                           # Uncommitted changes
     git diff --name-only HEAD               # Changed files
     git log -1 --stat                       # Recent commit
     ```

**3. Analyzes the changes** to determine:
   - Target platform (AWS, GCP, Azure, vSphere, etc.)
   - Test requirements (e2e, upgrade, UPI, special configs)
   - Existing test patterns to follow

**4. Creates dedicated step-registry components**:
   - `<step-name>-ref.yaml` - Step metadata and configuration
   - `<step-name>-commands.sh` - Test execution script
   - `OWNERS` file - Team ownership (if new directory)

**5. Adds test configuration** to installer CI config:
   - Configures appropriate cluster profile
   - Sets up environment variables
   - References the new step in test phase
   - Reuses existing pre/post chains for setup/cleanup

**6. Validates and generates** downstream artifacts:
   - Runs `make validate-step-registry`
   - Runs `make update` to generate Prow jobs
   - Shows git diff of all changes

**7. Provides summary** with:
   - Test name and platform
   - Trigger conditions
   - Created step files
   - Modified config files
   - Next steps for testing

#### Usage Examples

##### Example 1: Creating Test from PR URL

```bash
/installer-add-test https://github.com/openshift/installer/pull/8123

# Command will:
# 1. Fetch PR from GitHub
# 2. Extract: "Add support for AWS Local Zones"
# 3. Identify changed files: pkg/asset/installconfig/aws/*.go
# 4. Create step: installer-e2e-aws-local-zones
# 5. Add test config to installer CI
# 6. Generate Prow jobs
```

**What gets created:**
```
ci-operator/step-registry/installer/e2e/aws-local-zones/
├── installer-e2e-aws-local-zones-ref.yaml
├── installer-e2e-aws-local-zones-commands.sh
└── OWNERS

Modified:
- ci-operator/config/openshift/installer/openshift-installer-main.yaml
- ci-operator/jobs/openshift/installer/openshift-installer-main-presubmits.yaml
```

##### Example 2: Creating Test from Local Changes

```bash
# You're working on installer locally with uncommitted changes
cd /path/to/installer
# Made changes to pkg/asset/installconfig/gcp/edgezones.go

# In release repo, run:
/installer-add-test /path/to/installer

# Command will:
# 1. Check directory exists and is git repo
# 2. Run git diff HEAD to see your changes
# 3. Analyze: GCP edge zones feature
# 4. Create step: installer-e2e-gcp-edge-zones
# 5. Add test config
# 6. Generate Prow jobs
```

##### Example 3: Creating Test from Recent Commit

```bash
# You have a committed change in installer repo
cd /path/to/installer
git log -1  # Shows: "azure: add availability zones support"

# In release repo, run:
/installer-add-test /path/to/installer

# Command will:
# 1. Find no uncommitted changes
# 2. Analyze recent commit
# 3. Create test for Azure availability zones
```

#### Key Features

##### 1. Dual Input Support

Works with both remote and local sources:
- **GitHub PR**: Fetches from internet, analyzes PR description/files
- **Local directory**: Analyzes git diff and commits

##### 2. Intelligent Change Detection

For local directories:
- Checks uncommitted changes first (`git diff HEAD`)
- Falls back to recent commits if nothing uncommitted
- Extracts context from commit messages
- Identifies platform from file paths

##### 3. Dedicated Step Creation

Always creates reusable step-registry components:
- Follows naming convention: `installer-e2e-<platform>-<feature>`
- Includes proper documentation
- Sets appropriate resource limits
- Creates executable test scripts

##### 4. Pattern Matching

Searches for similar existing tests:
- Identifies appropriate workflows to reference
- Uses consistent naming patterns
- Follows platform-specific conventions

##### 5. Complete Validation

Ensures correctness:
- Validates step-registry structure
- Checks YAML syntax
- Generates Prow jobs
- Shows all changes with git diff

##### 6. Team Ownership

Creates OWNERS files for new directories:
- Includes installer team members
- Sets up proper approvers and reviewers

#### What Gets Created

**Step Registry Components** (in `ci-operator/step-registry/`):
```
installer/e2e/<feature>/
├── installer-e2e-<platform>-<feature>-ref.yaml    # Step metadata
├── installer-e2e-<platform>-<feature>-commands.sh # Test script
└── OWNERS                                          # Team ownership
```

**Test Configuration** (in `ci-operator/config/openshift/installer/`):
```yaml
tests:
  - as: e2e-<platform>-<feature>
    run_if_changed: <platform>
    optional: true
    steps:
      cluster_profile: <platform>-N
      env:
        FEATURE_ENABLED: "yes"
      pre:
      - chain: ipi-<platform>-pre
      test:
      - ref: installer-e2e-<platform>-<feature>
      post:
      - chain: ipi-<platform>-post
```

**Generated Prow Jobs** (in `ci-operator/jobs/openshift/installer/`):
- Automatically created by `make update`
- Should not be manually edited

#### Common Use Cases

##### 1. Review PR and Add Test

**Scenario**: Reviewing installer PR, want to add CI test

```bash
# In PR review, copy URL
/installer-add-test https://github.com/openshift/installer/pull/XXXXX

# Test automatically created based on PR changes
```

##### 2. Local Development Workflow

**Scenario**: Working on installer feature locally

```bash
# Make changes to installer
cd ~/code/installer
vim pkg/asset/installconfig/aws/localzones.go

# Create test without committing/pushing
cd ~/code/release
/installer-add-test ~/code/installer

# Test job created from local changes
```

##### 3. Post-Commit Test Addition

**Scenario**: Feature merged but forgot to add test

```bash
# Installer change already merged
# Create test by pointing to local clone
/installer-add-test /path/to/installer

# Analyzes recent commit, creates test
```

##### 4. Prototype Testing

**Scenario**: Experimenting with installer changes

```bash
# Try different approaches locally
# Create tests without creating PRs
/installer-add-test /path/to/installer

# Quick iteration on test configuration
```

#### Integration with Other Commands

Often used together with `/step-finder`:

```bash
# First, search for similar existing tests
/step-finder aws edge zones workflow

# Review existing patterns
# Then create the new test
/installer-add-test https://github.com/openshift/installer/pull/XXXXX
```

#### Best Practices

##### 1. Use Appropriate Input Type

- **PR URL**: When reviewing/planning based on PR
- **Local path**: When actively developing/prototyping

##### 2. Review Generated Files

Always review before committing:
- Check test logic in `-commands.sh`
- Verify environment variables
- Ensure appropriate trigger conditions

##### 3. Test Locally If Possible

After creation:
- Review the test script
- Check for syntax errors
- Validate the configuration

##### 4. Keep Changes Focused

For local directory usage:
- Stage related changes only
- Clear diff helps with accurate analysis

#### Files Modified

The command typically modifies:
1. `ci-operator/step-registry/installer/e2e/<feature>/` - New directory with step files
2. `ci-operator/config/openshift/installer/openshift-installer-main.yaml` - Test config
3. `ci-operator/jobs/openshift/installer/openshift-installer-main-presubmits.yaml` - Generated (auto-updated)

#### Input Detection Logic

The command automatically detects input type:

**PR URL indicators:**
- Contains "github.com"
- Contains "/pull/"
- Matches pattern: `https://github.com/<org>/<repo>/pull/<number>`

**Local directory indicators:**
- Starts with `/` or `./` or `~/`
- Does not contain "github.com"
- Path exists on filesystem

#### Error Handling

Common errors and solutions:

| Error | Cause | Solution |
|-------|-------|----------|
| Directory not found | Invalid path | Check path is correct and absolute |
| Not a git repository | Directory isn't git repo | Ensure you're pointing to installer clone |
| No changes found | No diff or commits | Make changes or commit something first |
| WebFetch failed | Invalid PR URL | Verify PR exists and is accessible |
| Step validation failed | Invalid YAML syntax | Review generated step files |
| Make update failed | Config syntax error | Check error message, fix YAML |

#### Limitations

- Only works for installer repository (not other repos)
- Requires PR to be accessible or local repo to be valid git repo
- May need manual adjustments for complex test scenarios
- Best effort analysis - review always required

#### Next Steps After Running

1. **Review generated files** - Check all created/modified files
2. **Adjust test logic** - Fine-tune the test script if needed
3. **Run validation** - Already done by command, but verify output
4. **Test locally** - If possible, test the configuration
5. **Commit changes** - Create PR with all generated files
6. **Monitor CI** - Watch for successful job execution

#### Comparison: PR URL vs Local Directory

| Aspect | PR URL | Local Directory |
|--------|--------|-----------------|
| **Source** | GitHub PR page | Local git repository |
| **Network** | Requires internet | Works offline |
| **Changes** | Merged + uncommitted PR changes | Committed + uncommitted local changes |
| **Context** | PR description, comments | Commit messages, diff |
| **Use case** | Review, planning | Development, prototyping |
| **Speed** | Slower (WebFetch) | Faster (local git) |

## Use Cases

### 1. Setting Up New CI Tests

**Scenario**: Adding AWS e2e tests to a new repository

```bash
/step-finder ipi aws

# Review workflows, pick one like 'ipi-aws-workflow'
# Add to ci-operator/config/<org>/<repo>/<branch>.yaml:
tests:
  - as: e2e-aws
    workflow: ipi-aws
```

### 2. Finding Upgrade Test Components

**Scenario**: Need to add upgrade tests for GCP

```bash
/step-finder gcp upgrade workflow

# Find relevant workflows like 'openshift-upgrade-gcp'
# See dependencies and environment variables needed
# Copy usage pattern to your config
```

### 3. Discovering Specialized Steps

**Scenario**: Need FIPS-compliant testing

```bash
/step-finder fips

# Find all FIPS-related components
# See which platforms support FIPS testing
# Understand required configuration
```

### 4. Checking Component Popularity

**Scenario**: Multiple similar components exist, which to choose?

```bash
/step-finder aws install all yes

# See which component is most widely used
# Review real usage examples
# Pick the most popular/maintained option
```

### 5. Avoiding Duplication

**Scenario**: About to create a new step for operator installation

```bash
/step-finder install operator step

# Discover existing 'install-operators-ref' step
# Reuse instead of creating new
# Save maintenance effort
```

### 6. Understanding Impact Before Changes (NEW!)

**Scenario**: Need to modify `openshift-e2e-test` step, want to know the impact

```bash
/step-finder openshift-e2e-test

# Results show:
# Used By: 156 workflows/chains
# Impact: 🔴 HIGH - Changes may have wide-reaching effects
#
# This tells you:
# - Need extensive testing across multiple workflows
# - Coordinate with other teams
# - Consider backward compatibility
# - May need staged rollout
```

**Scenario**: Want to modify `ipi-aws-pre-stableinitial` chain

```bash
/step-finder ipi-aws-pre-stableinitial

# Results show:
# Used By: 23 workflows
# Impact: 🟡 MEDIUM - Thorough testing required
#
# This tells you:
# - Test with affected workflows
# - Review dependent components
# - Moderate risk level
```

**Scenario**: Creating PR to update a step, need to know testing scope

```bash
/step-finder <your-step-name>

# If Impact is LOW (1-9 uses):
# - Test with those specific workflows
# - Lower risk, faster review
#
# If Impact is NONE (0 uses):
# - May be orphaned, safe to deprecate
# - Or it's a new top-level workflow
```

## Best Practices

### 1. Always Search First

Before creating new step-registry components:
- Use `/step-finder` to check for existing solutions
- Review components in related directories
- Check for patterns you can reuse

### 2. Start Broad, Narrow Down

```bash
# Start broad
/step-finder aws

# See results, then narrow
/step-finder aws upgrade

# Further narrow with type filter
/step-finder aws upgrade workflow
```

### 3. Use Real Usage Examples

When unsure about a component:
```bash
/step-finder <query> all yes
```
Learn from how other repositories use it.

### 4. Check Dependencies

For workflows/chains:
- Review the dependency tree
- Understand what credentials are needed
- Verify environment variables

### 5. Verify Maintenance Status

- Prefer actively maintained components
- Check for deprecation warnings
- Look for recent modifications

## Examples in Context

### Example 1: Adding vSphere Disconnected Tests

```bash
/step-finder vsphere disconnected workflow

# Results show:
# - ipi-vsphere-disconnected-workflow
# - Requires govc credentials
# - Uses specific environment variables
# - Last modified: 2 weeks ago ✓

# Add to your config:
tests:
  - as: e2e-vsphere-disconnected
    workflow: ipi-vsphere-disconnected
```

### Example 2: Finding Must-Gather Steps

```bash
/step-finder must-gather step

# Results show multiple options:
# - gather-must-gather (generic)
# - acm-must-gather (ACM-specific)
# - odf-must-gather (ODF-specific)

# Pick the appropriate one for your component
```

### Example 3: Understanding Complex Workflows

```bash
/step-finder openshift-upgrade-aws workflow yes

# Shows:
# - Full dependency tree
# - Used by 47+ configs (very popular)
# - Environment variables explained
# - Real examples to copy from
```

## Integration with Development Workflow

1. **Discover** components: `/step-finder <query>`
2. **Examine** files: Open the YAML and shell scripts
3. **Reference** in your config: `ci-operator/config/<org>/<repo>/<branch>.yaml`
4. **Generate** jobs: `make jobs`
5. **Validate**: `make checkconfig`
6. **Commit**: Config and generated job files

## Tips for Effective Searching

### Keyword Strategy

**Platforms**: aws, azure, gcp, vsphere, metal, nutanix, openstack
**Actions**: install, upgrade, test, destroy, provision, configure, gather
**Test Types**: e2e, conformance, disruptive, serial, parallel, integration
**Components**: operator, cluster, network, storage, observability, monitoring
**Features**: disconnected, proxy, fips, ipv6, ovn, sno, dual-stack

### Common Patterns

```bash
# Platform-specific workflows
/step-finder ipi-<platform>          # e.g., ipi-aws, ipi-gcp

# Upgrade patterns
/step-finder openshift-upgrade-<platform>

# Install patterns
/step-finder install-operators

# Test patterns
/step-finder openshift-e2e-test
```

### Abbreviations

- `sno` = single-node-openshift
- `ipi` = installer-provisioned infrastructure
- `upi` = user-provisioned infrastructure
- `ovn` = OVN-Kubernetes networking
- `acm` = Advanced Cluster Management
- `odf` = OpenShift Data Foundation
- `mce` = multicluster engine

## Troubleshooting

### Too Many Results?

- Add more specific keywords
- Use component type filter
- Include platform or version

### Too Few Results?

- Use broader terms
- Try abbreviations
- Search by platform first
- Check for different naming patterns

### Component Seems Old?

- Check git log: `git log -- ci-operator/step-registry/path/to/file.yaml`
- Look for newer variants
- Ask in #forum-ocp-testplatform Slack

## Future Enhancements

Potential additions to `/step-finder`:

1. **Reverse dependencies**: Show what uses this component
2. **Visual dependency trees**: ASCII tree diagrams
3. **Export results**: Save to markdown file
4. **Version filtering**: Find components for specific OpenShift versions
5. **Platform filtering**: Exclude certain platforms
6. **Interactive refinement**: Follow-up questions to narrow results

## Documentation

- **Command README**: `.claude/commands/README.md`
- **This file**: `.claude/SLASH_COMMANDS.md`
- **Repository guide**: `CLAUDE.md`

## Support

- Slack: #forum-ocp-testplatform
- Issues: File in openshift/release repository
- Docs: https://docs.ci.openshift.org/

---

**Created**: 2025-11-08
**Maintained by**: OpenShift Test Platform Team
**Repository**: github.com/openshift/release
