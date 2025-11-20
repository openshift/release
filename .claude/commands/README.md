# Claude Code Slash Commands for OpenShift Release Repository

This directory contains custom slash commands to help developers work with the OpenShift release repository more efficiently.

## Available Commands

### `/step-finder` - Step Registry Component Discovery

**Purpose**: Search and discover existing step-registry steps, workflows, and chains to reuse in CI configurations.

See detailed documentation below.

---

### `/migrate-variant-periodics` - Migrate Periodic Job Configurations

**Purpose**: Migrate OpenShift periodic CI job definitions from one release version to another by copying and transforming YAML configuration files.

**Usage**:
```bash
/migrate-variant-periodics <from_release> <to_release> [path] [--skip-existing]
```

**Parameters**:
- `from_release` (required): Source release version (e.g., "4.17", "4.18")
- `to_release` (required): Target release version (e.g., "4.18", "4.19")
- `path` (optional): Directory path to search for periodic files. Default: ci-operator/config/
- `skip_existing` (optional): Flag "--skip-existing" to automatically skip existing target files without prompting

**Examples**:
```bash
# Migrate all periodic jobs from 4.17 to 4.18
/migrate-variant-periodics 4.17 4.18

# Migrate specific repository
/migrate-variant-periodics 4.18 4.19 ci-operator/config/openshift/etcd

# Migrate entire organization
/migrate-variant-periodics 4.19 4.20 ci-operator/config/openshift

# Migrate with automatic skip of existing files
/migrate-variant-periodics 4.17 4.18 --skip-existing
```

**What it does**:
- Uses the `.claude/scripts/migrate_periodic_file.py` script to automate migration
- Transforms version references (base images, builder tags, registry paths, release names, branch metadata)
- Regenerates randomized cron schedules to avoid thundering herd
- Maintains existing interval schedules
- Creates new periodic configuration files for the target release
- Validates YAML structure
- **Automatically runs `make update`** after migration to regenerate all downstream artifacts (Prow jobs, configs, etc.)

**Implementation**:
- The command orchestrates the migration workflow and user interactions
- Actual file transformation is delegated to `.claude/scripts/migrate_periodic_file.py`
- Ensures consistent transformations across all periodic files
- Runs `make update` automatically at the end to generate job configs and update all related files

**CRITICAL Security Note**:
- ⚠️ **NEVER migrates files under `openshift-priv/`** - These are private repositories with special security considerations
- The command automatically excludes all `ci-operator/config/openshift-priv/` files from migration
- openshift-priv configurations must be handled separately by authorized personnel

---

### `/find-missing-variant-periodics` - Find Missing Periodic Configurations

**Purpose**: Identify periodic job configurations that exist for one release but are missing for another.

**Usage**:
```bash
/find-missing-variant-periodics <from_release> <to_release> [path]
```

**Parameters**:
- `from_release` (required): Source release version to search for existing configurations
- `to_release` (required): Target release version to check for missing configurations
- `path` (optional): Directory path to search for periodic files. Default: ci-operator/config/

**Examples**:
```bash
# Find all missing periodics from 4.17 to 4.18
/find-missing-variant-periodics 4.17 4.18

# Check specific repository
/find-missing-variant-periodics 4.18 4.19 ci-operator/config/openshift/cloud-credential-operator

# Check entire organization
/find-missing-variant-periodics 4.19 4.20 ci-operator/config/openshift
```

**What it does**:
- Read-only analysis - doesn't modify any files
- Identifies which periodic configs exist for one release but are missing for another
- Provides statistics (total, missing, existing counts and percentages)
- Suggests next steps for migration
- Use this before `/migrate-variant-periodics` to understand scope of work

---

## Step Finder Detailed Documentation

### `/step-finder` - Step Registry Component Discovery

**Purpose**: Search and discover existing step-registry steps, workflows, and chains to reuse in CI configurations.

**Why Use It**: The step-registry contains over 4,400 reusable CI components (2,116 steps, 1,322 workflows, 985 chains). This command helps you find the right component instead of creating duplicates.

#### Usage

```bash
/step-finder <search_query> [component_type] [show_usage] [show_reverse_deps]
```

#### Parameters

- `search_query` (required): Keywords to search for. Can be platform names, functionality, component names, or any combination.
- `component_type` (optional): Filter by component type - `step`, `workflow`, `chain`, or `all` (default: all)
- `show_usage` (optional): Show real usage examples from ci-operator configs - `yes` or `no` (default: no)
- `show_reverse_deps` (optional): Show reverse dependencies (which workflows/chains use this component) - `yes` or `no` (default: yes)

#### Examples

```bash
# Basic search - Find AWS upgrade testing components
/step-finder aws upgrade

# Filter by type - Find only workflow components
/step-finder aws upgrade workflow

# With real usage examples - See which repos use it
/step-finder install operator all yes

# With reverse dependencies - See what uses this component (default: enabled)
/step-finder openshift-e2e-test

# Disable reverse dependencies for faster results
/step-finder aws upgrade all no no

# Find only steps, with usage examples and reverse deps
/step-finder must-gather step yes yes

# Find operator installation steps
/step-finder install operator

# Find vSphere disconnected environment components
/step-finder vsphere disconnected

# Find bare metal FIPS-related components
/step-finder metal fips

# Find IPv6 networking tests
/step-finder ipv6 network

# Find storage conformance tests
/step-finder storage conformance
```

#### Search Tips

**Platform Keywords**:
- `aws`, `azure`, `gcp`, `vsphere`, `metal`, `alibabacloud`, `ibmcloud`, `nutanix`, `openstack`

**Action Keywords**:
- `install`, `upgrade`, `test`, `destroy`, `provision`, `deprovision`, `configure`, `gather`

**Test Type Keywords**:
- `e2e`, `conformance`, `disruptive`, `serial`, `parallel`, `integration`, `performance`

**Component Keywords**:
- `operator`, `cluster`, `network`, `storage`, `observability`, `security`, `monitoring`

**Special Environment Keywords**:
- `disconnected`, `proxy`, `fips`, `ipv6`, `ovn`, `metallb`, `dual-stack`, `single-node`

#### What the Command Returns

For each matching component, you'll see:

1. **Component Name & Type** (step/workflow/chain)
2. **File Location** - Full path to the YAML file
3. **Description** - From the documentation field
4. **Usage Example** - How to reference it in your ci-operator config
5. **Environment Variables** - Configurable parameters
6. **Dependencies** - Required images or other components (what this component uses)
7. **Reverse Dependencies** (default: enabled) - Which workflows/chains use this component
8. **Impact Assessment** - Risk level based on usage (HIGH/MEDIUM/LOW/NONE)
9. **Real Usage Examples** (optional) - Actual CI configs using the component
10. **Related Components** - Similar or complementary components
11. **Status** - Maintenance status and deprecation warnings

#### Sample Output

```
Found 3 relevant components for "openshift-e2e-test":

### openshift-e2e-test (type: step)
**File**: ci-operator/step-registry/openshift/e2e/test/openshift-e2e-test-ref.yaml
**Description**: Runs the OpenShift conformance test suite

**Usage**:
  tests:
  - as: e2e
    steps:
      test:
      - ref: openshift-e2e-test

**Environment Variables**:
- TEST_SUITE: conformance/parallel (which test suite to run)
- TEST_SKIPS: Optional tests to skip

**Used By** (Reverse Dependencies): Found in 156 workflows/chains:
- openshift-upgrade-aws-workflow.yaml (test phase)
- openshift-upgrade-gcp-workflow.yaml (test phase)
- ipi-aws-workflow.yaml (test phase)
- firewatch-ipi-aws-workflow.yaml (test phase)
- ... and 152 more

**Impact**: 🔴 HIGH - This component is used by 156 other components. Changes may have wide-reaching effects.

**Status**: ✓ Active (last modified 1 week ago)

---

### openshift-upgrade-aws (type: workflow)
**File**: ci-operator/step-registry/openshift/upgrade/aws/openshift-upgrade-aws-workflow.yaml
**Description**: Executes upgrade end-to-end test suite on AWS with default cluster configuration

**Usage**:
  tests:
  - as: e2e-aws-upgrade
    workflow: openshift-upgrade-aws

**Environment Variables**:
- TEST_TYPE: upgrade (default)
- TEST_UPGRADE_OPTIONS: "" (additional upgrade options)

**Dependencies** (what this workflow uses):
- Pre: ipi-aws-pre-stableinitial (chain)
- Test: openshift-e2e-test (ref)
- Post: ipi-aws-post (chain)

**Used By** (Reverse Dependencies): Found in 0 workflows/chains

**Impact**: ℹ️ NONE - This is a top-level workflow, not reused by other components.

**Status**: ✓ Active (last modified 2 weeks ago)

---

### ipi-aws-pre-stableinitial (type: chain)
**File**: ci-operator/step-registry/ipi/aws/pre/stableinitial/...
**Description**: Upgrade tests for multi-architecture (heterogeneous) AWS clusters
...
```

## Understanding Step Registry Components

### Steps (`*-ref.yaml`)

Atomic, reusable tasks that perform a single operation. Each step consists of:
- A `*-ref.yaml` file with metadata
- A `*-commands.sh` script with the actual implementation

**Example**:
- `openshift-e2e-test-ref.yaml` + `openshift-e2e-test-commands.sh`

**Usage in ci-operator config**:
```yaml
tests:
- as: e2e-test
  steps:
    test:
    - ref: openshift-e2e-test  # Reference the step
```

### Workflows (`*-workflow.yaml`)

Complete test scenarios that define the entire test lifecycle with three phases:
- **pre**: Setup and provisioning steps
- **test**: Actual test execution
- **post**: Cleanup and teardown

**Example**:
- `ipi-aws-workflow.yaml` - Full AWS cluster lifecycle

**Usage in ci-operator config**:
```yaml
tests:
- as: e2e-aws
  workflow: ipi-aws  # Reference the entire workflow
```

### Chains (`*-chain.yaml`)

Ordered sequences of steps that can be reused as a unit. Chains help compose multiple steps together.

**Example**:
- `acm-install-chain.yaml` - Chains together operator installation and MCH setup

**Usage in ci-operator config**:
```yaml
tests:
- as: my-test
  steps:
    pre:
    - chain: acm-install  # Reference the chain
    test:
    - ref: my-test-step
```

## Common Workflows

### Finding Components for Common Tasks

#### 1. Setting up a new test on AWS
```bash
/step-finder ipi aws
```
Look for `ipi-aws-workflow.yaml` and variants.

#### 2. Adding upgrade tests
```bash
/step-finder upgrade <platform>
```
Example: `/step-finder upgrade gcp`

#### 3. Installing operators
```bash
/step-finder install operator
```
Look for `install-operators-ref.yaml` and related steps.

#### 4. Disconnected/air-gapped testing
```bash
/step-finder disconnected <platform>
```
Example: `/step-finder disconnected vsphere`

#### 5. Gathering must-gather artifacts
```bash
/step-finder must-gather
```

#### 6. FIPS compliance testing
```bash
/step-finder fips
```

## Best Practices

### 1. Search Before Creating
Always search the step-registry before creating new steps. Reusing existing components:
- Reduces maintenance burden
- Ensures consistency across tests
- Leverages battle-tested code
- Benefits from ongoing improvements

### 2. Start Broad, Then Narrow
Begin with general keywords, then refine:
```bash
/step-finder aws           # See all AWS components
/step-finder aws upgrade   # Narrow to upgrade scenarios
```

### 3. Check Related Components
When you find a component, examine:
- Other files in the same directory
- Components it references (in pre/test/post)
- Components with similar names

### 4. Use Reverse Dependencies to Understand Impact
Reverse dependencies (enabled by default) show which workflows/chains use a component. This helps you:
- **Assess change impact**: See how many components would be affected
- **Find usage patterns**: Learn how others use the component
- **Identify critical components**: HIGH impact components need careful testing
- **Discover dependent workflows**: Understand the blast radius of changes

**Impact Levels**:
- 🔴 **HIGH** (100+ uses): Core infrastructure component, coordinate changes carefully
- 🟡 **MEDIUM** (10-99 uses): Widely used, thorough testing required
- 🟢 **LOW** (1-9 uses): Limited usage, standard testing sufficient
- ℹ️ **NONE** (0 uses): Top-level workflow or potentially orphaned component

**Example**:
```bash
# Check what uses openshift-e2e-test
/step-finder openshift-e2e-test

# Result shows: Used by 156 workflows/chains - HIGH impact
# This tells you changes will affect many workflows
```

### 5. Read the Source
The command shows you file paths - always read the actual YAML and shell scripts to understand:
- Exact behavior
- Required credentials
- Environment variable meanings
- Supported OpenShift versions

### 6. Look for Patterns
Component naming follows patterns:
- `<platform>-<action>-<component>`
- Example: `ipi-aws-pre` = IPI (installer) + AWS + pre phase

## File Organization

Step-registry components are organized by primary concern:

```
ci-operator/step-registry/
├── aws/                    # AWS-specific steps
├── azure/                  # Azure-specific steps
├── gcp/                    # GCP-specific steps
├── vsphere/                # vSphere-specific steps
├── openshift/              # Core OpenShift testing
│   ├── e2e/               # End-to-end tests
│   ├── upgrade/           # Upgrade tests
│   └── conformance/       # Conformance tests
├── ipi/                    # Installer-provisioned infrastructure
├── upi/                    # User-provisioned infrastructure
└── <component-name>/       # Component-specific (acm, odf, etc.)
```

## Integration with CI Workflow

1. **Discover** components using `/step-finder`
2. **Examine** the YAML files and shell scripts
3. **Reference** in your `ci-operator/config/<org>/<repo>/<branch>.yaml`
4. **Generate** job configs with `make jobs`
5. **Validate** with `make checkconfig`
6. **Commit** both config and generated job files

## Tips for Effective Searching

### Combine Multiple Keywords
```bash
/step-finder aws e2e serial      # AWS + e2e + serial tests
/step-finder operator upgrade    # Operator upgrade scenarios
```

### Use Specific Version Keywords
```bash
/step-finder openshift 4.14      # Version-specific components
```

### Search by Network Type
```bash
/step-finder ovn                 # OVN networking
/step-finder metallb             # MetalLB load balancer
```

### Search by Security Features
```bash
/step-finder fips                # FIPS mode
/step-finder encryption          # Encryption-related
```

## Troubleshooting

### Too Many Results?
- Add more specific keywords
- Include platform name
- Add version or feature flags

### Too Few Results?
- Use broader keywords
- Try different term variations (e.g., "provisioning" vs "provision")
- Search for platform first, then narrow down
- Check for abbreviations (e.g., "sno" for single-node-openshift)

### Component Seems Outdated?
- Check git history: `git log -- <file-path>`
- Look for newer variants in the same directory
- Search for similar components with recent modifications

## Contributing

When creating new step-registry components:

1. **Search first** - Use `/step-finder` to ensure you're not duplicating
2. **Follow patterns** - Mimic existing component structure and naming
3. **Document well** - Add clear documentation fields
4. **Make it reusable** - Use environment variables for configuration
5. **Test thoroughly** - Validate before submitting

## Additional Resources

- [CI Operator Documentation](https://docs.ci.openshift.org/docs/architecture/ci-operator/)
- [Step Registry Documentation](https://docs.ci.openshift.org/docs/architecture/step-registry/)
- Repository CLAUDE.md for more development commands

## Getting Help

If you can't find what you need:
1. Try different search term combinations
2. Browse the step-registry directories manually
3. Ask in #forum-ocp-testplatform Slack channel
4. Check recent PRs for new component additions

---

**Last Updated**: 2025-11-08
**Maintainer**: OpenShift Test Platform Team
