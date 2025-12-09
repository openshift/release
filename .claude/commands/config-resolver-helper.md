---
name: config-resolver-helper
description: Help understand ci-operator config resolution, test how configs resolve, and debug configuration issues
parameters:
  - name: action
    description: Action to perform - "resolve", "explain", "validate", or "help" (default: help)
    required: false
  - name: config_path
    description: Path to ci-operator config file (e.g., "ci-operator/config/openshift/origin/openshift-origin-master.yaml")
    required: false
  - name: test_name
    description: Optional test name to resolve (if resolving specific test)
    required: false
---
You are helping users understand and work with ci-operator configuration resolution.

## Context

The ci-operator config resolver processes configuration files and resolves:
- Step-registry references (workflows, chains, steps)
- Image references and builds
- Test definitions and their dependencies
- Environment variables and parameters
- Release image references

The resolver validates configurations and expands references before job execution.

## Your Task

Based on the user's request: action="{{action}}"{{#if config_path}}, config="{{config_path}}"{{/if}}{{#if test_name}}, test="{{test_name}}"{{/if}}

1. **Provide guidance** based on the action:

   **resolve** - Resolve a configuration:
   - Explain how the config resolves
   - Show resolved test definitions
   - Display expanded step-registry references
   - Show image build dependencies
   - Explain environment variable resolution

   **explain** - Explain config resolution:
   - How step-registry references work
   - How workflows expand to steps
   - How chains compose steps
   - How images are resolved
   - How releases are handled

   **validate** - Validate config resolution:
   - Check for missing references
   - Verify step-registry components exist
   - Validate image references
   - Check environment variable usage
   - Identify circular dependencies

   **help** - General help:
   - Overview of config resolution
   - Common resolution issues
   - Tools and commands
   - Documentation references

2. **Resolution Process**: Parse YAML → Resolve step-registry → Expand workflows/chains → Validate

3. **How It Works**:
   - Workflows expand to chains/steps
   - Chains expand to step lists
   - Steps include env vars and defaults
   - Images and dependencies resolved

4. **Common Issues**:
   - Missing component: Use `/step-finder` to find correct name
   - Invalid reference: Check spelling and existence
   - Circular dependency: Review workflow/chain deps

5. **Tools**:
   ```bash
   make validate-step-registry
   make checkconfig
   ci-operator-configresolver --config <file> --registry <registry>
   ```

## Example Output

```
**Resolved Test**: `e2e-aws`
- Workflow `ipi-aws` expands to:
  - Pre: `ipi-aws-pre` chain
  - Test: `openshift-e2e-test` step
  - Post: `ipi-aws-post` chain

**Validation**: ✅ All references exist, no circular deps

**Commands**: `make validate-step-registry`, `make checkconfig`
```

Now help the user with: "{{action}}"{{#if config_path}} for config "{{config_path}}"{{/if}}{{#if test_name}} test "{{test_name}}"{{/if}}

