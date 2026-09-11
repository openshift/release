---
name: step-finder
description: Search and discover existing step-registry steps, workflows, and chains to reuse in CI configurations
parameters:
  - name: search_query
    description: Keywords to search for (e.g., "aws e2e", "install operator", "upgrade"). Can be platform, functionality, or component name.
    required: true
  - name: component_type
    description: Optional filter by component type (step, workflow, chain, or all). Default is all.
    required: false
  - name: show_usage
    description: Optional flag to show real usage examples from ci-operator configs (yes/no). Default is no.
    required: false
  - name: show_reverse_deps
    description: Optional flag to show reverse dependencies - which workflows/chains use this component (yes/no). Default is yes.
    required: false
---

You are helping users discover and reuse existing step-registry components in the OpenShift CI infrastructure.

## Context

The step-registry contains **2100+ steps**, **1300+ workflows**, and **900+ chains** - over 4400 reusable CI components.
Your goal is to help users find the right components instead of duplicating existing work.

## Component Types

1. **Steps** (`*-ref.yaml`): Atomic tasks with corresponding `-commands.sh` scripts
   - Example: `openshift-e2e-test-ref.yaml` + `openshift-e2e-test-commands.sh`

2. **Workflows** (`*-workflow.yaml`): Complete test scenarios with pre/test/post phases
   - Example: `ipi-aws-workflow.yaml` defines full AWS cluster lifecycle

3. **Chains** (`*-chain.yaml`): Ordered sequences of steps
   - Example: `acm-install-chain.yaml` chains multiple installation steps

## Your Task

Based on the user's search query: "{{search_query}}"
{{#if component_type}}Filter by component type: {{component_type}}{{/if}}
{{#if show_usage}}Include real usage examples: {{show_usage}}{{/if}}
{{#if show_reverse_deps}}Show reverse dependencies: {{show_reverse_deps}}{{else}}Show reverse dependencies: yes (default){{/if}}

1. **Search the step-registry** using these strategies:
   - Search by file name patterns matching keywords
   - Search documentation and descriptions in YAML files
   - Look for related components in the same directory structure
   - Consider common naming conventions (platform-action-component)
   {{#if component_type}}
   - IMPORTANT: Only show components of type: {{component_type}}
   {{/if}}

2. **Present findings** in this format for each relevant component:

   ```
   ### [Component Name] (type: step|workflow|chain)
   **File**: `ci-operator/step-registry/path/to/file.yaml`
   **Description**: [from documentation field]
   **Usage**: How to reference it in ci-operator config
   {{#if show_usage}}
   **Real Usage Examples**: Found in X config files:
   - ci-operator/config/org/repo/branch.yaml
   {{/if}}
   **Dependencies**: [For workflows/chains: list referenced steps/chains]
   **Credentials**: [If any credentials are required]
   {{#if show_reverse_deps}}
   **Used By** (Reverse Dependencies): [List workflows/chains that reference this component]
   {{/if}}
   **Related**: Other components in the same category
   **Status**: [Check for deprecation warnings in documentation]
   ```

3. **Provide examples** of how to use the component:
   - For steps: Show the `ref:` syntax
   - For workflows: Show the `workflow:` syntax
   - For chains: Show the `chain:` syntax

4. **Suggest alternatives** if you find multiple similar components:
   - Explain differences between similar options
   - Recommend which to use based on common use cases

5. **Enhanced Information** (optional based on parameters):
   {{#if show_usage}}
   - Search through `ci-operator/config/**/*.yaml` to find actual usage
   - Count how many repositories use each component (popularity)
   - Show 2-3 real examples of configs that reference the component
   {{/if}}
   - For workflows/chains: Parse and show the dependency tree (what steps/chains it uses)
   {{#if show_reverse_deps}}
   - **Reverse Dependencies** (default: enabled): For each component found, search through the step-registry to find which workflows and chains reference it:
     * For steps: Search all `*-workflow.yaml` and `*-chain.yaml` files for `- ref: <step-name>`
     * For chains: Search all `*-workflow.yaml` and `*-chain.yaml` files for `- chain: <chain-name>`
     * For workflows: Search `ci-operator/config/**/*.yaml` for `workflow: <workflow-name>`
     * Show count and list up to 5-10 examples of components that use it
     * This helps understand the impact of modifying a component
     * Useful for determining if a component is widely used or can be safely changed
   {{/if}}
   - Check for deprecation keywords in documentation fields
   - Note if component hasn't been modified in over a year (may be stale)

## Search Tips

- Platform keywords: aws, azure, gcp, vsphere, metal, alibabacloud, ibmcloud, nutanix
- Actions: install, upgrade, test, destroy, provision, deprovision, configure
- Test types: e2e, conformance, disruptive, serial, parallel
- Components: operator, cluster, network, storage, observability, security
- Special cases: disconnected, proxy, fips, ipv6, ovn, metallb

## Important

- **Always read the actual files** - don't guess what they contain
- **Show file paths** so users can examine them directly
- **Explain parameters** if the component has configurable environment variables
- **Note dependencies** if the component requires other components or credentials
- **Be specific** about which OpenShift versions are supported if mentioned

## Example Output

If searching for "openshift-e2e-test" with show_usage=yes and show_reverse_deps=yes:

```
Found 1 component matching "openshift-e2e-test":

### openshift-e2e-test (type: step)
**File**: `ci-operator/step-registry/openshift/e2e/test/openshift-e2e-test-ref.yaml`
**Description**: Runs the OpenShift conformance test suite
**Usage**: Can be used standalone or as part of workflows:
  tests:
  - as: e2e
    steps:
      test:
      - ref: openshift-e2e-test

**Environment Variables**:
- TEST_SUITE: conformance/parallel (which test suite to run)
- TEST_SKIPS: Optional tests to skip

**Used By** (Reverse Dependencies): Found in 156 workflows/chains:
- openshift-upgrade-aws-workflow.yaml (uses in test phase)
- openshift-upgrade-gcp-workflow.yaml (uses in test phase)
- openshift-upgrade-azure-workflow.yaml (uses in test phase)
- ipi-aws-workflow.yaml (uses in test phase)
- ipi-gcp-workflow.yaml (uses in test phase)
- firewatch-ipi-aws-workflow.yaml (uses in test phase)
- ... and 150 more

**Impact**: ⚠️ HIGH - This component is used by 156 other components. Changes may have wide-reaching effects.

**Real Usage Examples** (Used by 200+ config files):
- ci-operator/config/openshift/origin/openshift-origin-master.yaml
- ci-operator/config/openshift/kubernetes/openshift-kubernetes-master.yaml

**Status**: ✓ Active (last modified 1 week ago)

---

Found 5 relevant components for AWS e2e upgrade testing:

### openshift-upgrade-aws (type: workflow)
**File**: `ci-operator/step-registry/openshift/upgrade/aws/openshift-upgrade-aws-workflow.yaml`
**Description**: Executes upgrade end-to-end test suite on AWS with default cluster configuration
**Usage**: Reference in your ci-operator config:
  tests:
  - as: e2e-aws-upgrade
    workflow: openshift-upgrade-aws

**Environment Variables**:
- TEST_TYPE: upgrade
- TEST_UPGRADE_OPTIONS: "" (additional upgrade options)
- OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE: "release:initial"
- OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE: "release:latest"

**Dependencies** (pre → test → post):
- Pre: ipi-aws-pre-stableinitial (chain)
- Test: openshift-e2e-test (ref)
- Post: openshift-e2e-test-capabilities-check (ref), ipi-aws-post (chain)

**Used By** (Reverse Dependencies): Found in 0 workflows/chains (this is a top-level workflow)

**Real Usage Examples** (Used by 47 config files):
- ci-operator/config/openshift/origin/openshift-origin-master.yaml
- ci-operator/config/openshift/kubernetes/openshift-kubernetes-master.yaml
- ci-operator/config/openshift/cluster-network-operator/openshift-cluster-network-operator-master.yaml

**Impact**: ℹ️ LOW - This is a top-level workflow, not reused by other components.

**Status**: ✓ Active (last modified 2 weeks ago)

---

### ipi-aws-pre-stableinitial (type: chain)
**File**: `ci-operator/step-registry/ipi/aws/pre/stableinitial/ipi-aws-pre-stableinitial-chain.yaml`
**Description**: Provision AWS cluster using stable initial release
**Usage**: Reference in workflows as a pre chain

**Used By** (Reverse Dependencies): Found in 23 workflows:
- openshift-upgrade-aws-workflow.yaml
- openshift-upgrade-aws-cgroupsv1-workflow.yaml
- openshift-upgrade-aws-heterogeneous-workflow.yaml
- openshift-e2e-aws-upgrade-workflow.yaml
- ... and 19 more

**Impact**: ⚠️ MEDIUM - Used by 23 workflows. Test changes carefully.

**Status**: ✓ Active (last modified 1 month ago)

[Continue with more results...]
```

## Additional Advanced Features

You can also provide these insights when relevant:

1. **Reverse Dependencies**: Show which workflows/chains use this component and calculate impact level:
   - HIGH impact (100+ uses): Critical component, changes need extensive testing
   - MEDIUM impact (10-99 uses): Widely used, changes should be tested carefully
   - LOW impact (1-9 uses): Limited usage, lower risk to modify
   - NONE (0 uses): Not used by other components (may be top-level workflow or orphaned)

2. **Dependency Tree Visualization**: For complex workflows, show the full tree structure

3. **Deprecation Warnings**: Alert if documentation contains "deprecated", "legacy", or "obsolete"

4. **Maintenance Status**: Flag components not modified in over 12 months as potentially stale

5. **Related Components**: Suggest other components in the same directory or with similar purposes

6. **Common Patterns**: Identify if the component is part of a common pattern (e.g., ipi-<platform>-pre/test/post)

## Impact Assessment

When showing reverse dependencies, provide an impact assessment:
- **HIGH** (🔴): 100+ dependent components - Core infrastructure, changes need careful coordination
- **MEDIUM** (🟡): 10-99 dependent components - Widely used, thorough testing required
- **LOW** (🟢): 1-9 dependent components - Limited usage, standard testing sufficient
- **NONE** (ℹ️): 0 dependent components - Top-level workflow or potentially unused

Now begin your search based on the user's query: "{{search_query}}"
