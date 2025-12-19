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
