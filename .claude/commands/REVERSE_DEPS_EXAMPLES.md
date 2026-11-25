# Reverse Dependencies Feature - Test Examples

This document shows real examples of reverse dependencies discovered in the OpenShift release repository.

## Test Date
2025-11-08

## Example 1: High-Impact Step - `openshift-e2e-test`

### Command
```bash
/step-finder openshift-e2e-test
```

### Actual Results from Repository Search
```bash
$ grep -r "ref: openshift-e2e-test" ci-operator/step-registry --include="*.yaml" | wc -l
319
```

### Expected Output from /step-finder
```
### openshift-e2e-test (type: step)
**File**: ci-operator/step-registry/openshift/e2e/test/openshift-e2e-test-ref.yaml
**Description**: Runs the OpenShift conformance test suite

**Used By** (Reverse Dependencies): Found in 319 workflows/chains:
- openshift/e2e/alibabacloud/disk-csi/openshift-e2e-alibabacloud-disk-csi-workflow.yaml
- openshift/e2e/alibabacloud/openshift-e2e-alibabacloud-workflow.yaml
- openshift/e2e/azure/capi/openshift-e2e-azure-capi-workflow.yaml
- openshift/e2e/azure/ccm/install/openshift-e2e-azure-ccm-install-workflow.yaml
- openshift/upgrade/aws/openshift-upgrade-aws-workflow.yaml
- openshift/upgrade/gcp/openshift-upgrade-gcp-workflow.yaml
- openshift/upgrade/azure/openshift-upgrade-azure-workflow.yaml
- ipi-aws-workflow.yaml
- ipi-gcp-workflow.yaml
- firewatch-ipi-aws-workflow.yaml
- ... and 309 more

**Impact**: 🔴 **HIGH** - This component is used by 319 other components (319 workflows/chains). Changes may have wide-reaching effects across the entire CI infrastructure.

**Recommendation**:
- Extensive testing required across multiple platforms
- Coordinate changes with Test Platform team
- Consider backward compatibility carefully
- May need staged rollout or feature flags
```

**Impact Level**: 🔴 HIGH (100+ dependencies)

---

## Example 2: Medium-Impact Chain - `ipi-aws-pre`

### Command
```bash
/step-finder ipi-aws-pre
```

### Actual Results from Repository Search
```bash
$ grep -r "chain: ipi-aws-pre" ci-operator/step-registry --include="*.yaml" | wc -l
91
```

### Expected Output from /step-finder
```
### ipi-aws-pre (type: chain)
**File**: ci-operator/step-registry/ipi/aws/pre/ipi-aws-pre-chain.yaml
**Description**: Provision AWS cluster using IPI

**Used By** (Reverse Dependencies): Found in 91 workflows:
- 3scale/ipi/aws/3scale-ipi-aws-workflow.yaml
- acm/ipi/aws/acm-ipi-aws-workflow.yaml
- acm/ipi/aws/wait/acm-ipi-aws-wait-workflow.yaml
- aws-load-balancer/install/aws-load-balancer-install-workflow.yaml
- openshift/installer/aws/openshift-installer-aws-workflow.yaml
- ... and 86 more

**Impact**: 🟡 **MEDIUM** - This component is used by 91 workflows. Changes should be tested carefully with affected workflows.

**Recommendation**:
- Test with representative subset of affected workflows
- Review changes with AWS-focused teams
- Thorough testing required before merge
```

**Impact Level**: 🟡 MEDIUM (10-99 dependencies)

---

## Example 3: Top-Level Workflow - `openshift-upgrade-aws`

### Command
```bash
/step-finder openshift-upgrade-aws workflow
```

### Actual Results from Repository Search
```bash
# For workflows, we search ci-operator/config for usage
$ grep -r "workflow: openshift-upgrade-aws" ci-operator/config --include="*.yaml" | wc -l
2509
```

### Expected Output from /step-finder
```
### openshift-upgrade-aws (type: workflow)
**File**: ci-operator/step-registry/openshift/upgrade/aws/openshift-upgrade-aws-workflow.yaml
**Description**: Executes upgrade end-to-end test suite on AWS with default cluster configuration

**Dependencies** (what this workflow uses):
- Pre: ipi-aws-pre-stableinitial (chain)
- Test: openshift-e2e-test (ref)
- Post: openshift-e2e-test-capabilities-check (ref), ipi-aws-post (chain)

**Used By** (Reverse Dependencies):
- In step-registry: Found in 0 workflows/chains
- In ci-operator/config: Found in 2,509 repository configs

**Impact**: ℹ️ **WORKFLOW** - This is a top-level workflow used directly by 2,509 CI configurations. Not reused by other step-registry components, but widely used by repositories.

**Recommendation**:
- This is a top-level workflow interface
- Changes affect 2,509 repository configurations
- Maintain backward compatibility
- Announce changes to all teams
```

**Impact Level**: ℹ️ NONE for step-registry (0 workflows/chains use it)
**Config Usage**: Used by 2,509 repository configurations

---

## Example 4: Low-Impact Component

For a component with low usage (example: specialized test step):

### Expected Output
```
### acm-must-gather (type: step)
**File**: ci-operator/step-registry/acm/must-gather/acm-must-gather-ref.yaml
**Description**: Gather ACM must-gather artifacts

**Used By** (Reverse Dependencies): Found in 3 workflows:
- acm/ipi/aws/acm-ipi-aws-workflow.yaml
- acm/ipi/vsphere/acm-ipi-vsphere-workflow.yaml
- acm/tests/acm-tests-workflow.yaml

**Impact**: 🟢 **LOW** - This component is used by only 3 workflows. Changes have limited scope and lower risk.

**Recommendation**:
- Test with the 3 specific workflows
- Standard review process
- Low risk modification
```

**Impact Level**: 🟢 LOW (1-9 dependencies)

---

## Example 5: Orphaned Component (No Reverse Dependencies)

For a component not used anywhere:

### Expected Output
```
### example-unused-step (type: step)
**File**: ci-operator/step-registry/example/unused/example-unused-step-ref.yaml
**Description**: Example step that is no longer used

**Used By** (Reverse Dependencies): Found in 0 workflows/chains

**Impact**: ℹ️ **NONE** - This component is not used by any other components. It may be:
- An orphaned component that can be safely removed
- A newly created component not yet integrated
- A top-level workflow (check ci-operator/config for direct usage)

**Recommendation**:
- Check git history to determine if recently deprecated
- Search ci-operator/config/ to see if used directly by repositories
- Consider removing if truly orphaned
```

**Impact Level**: ℹ️ NONE (0 dependencies - potentially orphaned)

---

## Impact Level Distribution

Based on analysis of the step-registry:

| Impact Level | Range | Count (estimated) | Examples |
|--------------|-------|-------------------|----------|
| 🔴 HIGH | 100+ uses | ~50 components | openshift-e2e-test, ipi-aws-post, gather-must-gather |
| 🟡 MEDIUM | 10-99 uses | ~300 components | ipi-aws-pre, various platform-specific chains |
| 🟢 LOW | 1-9 uses | ~1500 components | Specialized test steps, component-specific helpers |
| ℹ️ NONE | 0 uses | ~700 components | Top-level workflows, potentially orphaned steps |

## Performance Considerations

The reverse dependencies feature searches through:
- ~1,322 workflow files
- ~985 chain files
- ~2,116 step ref files
- For workflows: Also searches ~50,000+ ci-operator config files

**Search Time Estimates**:
- Steps/Chains: <2 seconds (searching step-registry only)
- Workflows: 5-10 seconds (includes ci-operator/config search)

**Optimization**: The feature can be disabled with `show_reverse_deps=no` for faster results when only basic component info is needed.

---

## Validation Commands

To manually verify reverse dependencies:

```bash
# For a step
grep -r "ref: <step-name>" ci-operator/step-registry --include="*.yaml" | wc -l

# For a chain
grep -r "chain: <chain-name>" ci-operator/step-registry --include="*.yaml" | wc -l

# For a workflow (in step-registry)
grep -r "workflow: <workflow-name>" ci-operator/step-registry --include="*.yaml" | wc -l

# For a workflow (in ci-operator configs)
grep -r "workflow: <workflow-name>" ci-operator/config --include="*.yaml" | wc -l

# Show actual files
grep -r "ref: <step-name>" ci-operator/step-registry --include="*.yaml" | head -20
```

---

**Generated**: 2025-11-08
**Repository**: openshift/release
**Feature**: Reverse Dependencies for /step-finder
