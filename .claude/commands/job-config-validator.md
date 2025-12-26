---
name: job-config-validator
description: Validate CI job configurations and provide guidance on fixing issues
parameters:
  - name: config_path
    description: Path to ci-operator config file or directory to validate (e.g., "ci-operator/config/openshift/origin" or specific file)
    required: true
  - name: check_type
    description: Optional type of validation - "syntax", "structure", "references", "best-practices", or "all" (default: all)
    required: false
---
You are helping users validate CI job configurations in the OpenShift release repository.

## Context

CI configurations in `ci-operator/config/` must follow specific rules:
- File naming: `$org-$repo-$branch.yaml`
- Directory structure: `ci-operator/config/$org/$repo/`
- YAML syntax and structure
- Valid references to step-registry components
- Proper test definitions
- Correct image and build configurations

## Your Task

Based on the user's request to validate: "{{config_path}}"
{{#if check_type}}Validation type: {{check_type}}{{/if}}

1. **Read and analyze the configuration file(s)**:
   - Check file naming convention
   - Validate YAML syntax
   - Verify directory structure
   - Check for required fields
   {{#if check_type}}
   - Focus on: {{check_type}}
   {{/if}}

2. **Validate against common issues**:

   **Syntax Issues**:
   - Invalid YAML syntax
   - Missing required fields
   - Incorrect indentation
   - Duplicate keys

   **Structure Issues**:
   - Incorrect file naming (`$org-$repo-$branch.yaml`)
   - Wrong directory structure
   - Missing required sections (build_root, images, tests, etc.)
   - Invalid field types

   **Reference Issues**:
   - Invalid step-registry references (workflows, chains, steps)
   - Missing step-registry components
   - Incorrect reference syntax
   - Circular dependencies

   **Best Practices**:
   - Using deprecated components
   - Missing documentation
   - Inefficient configurations
   - Security concerns

3. **Provide validation results** concisely:

   ```
   ## Validation Results

   ✅ Passed: [count]
   ⚠️ Warnings: [list key issues only]
   ❌ Errors: [list with brief fixes]
   📝 Recommendations: [top 2-3 only]
   ```

4. **Key Validation Rules**:
   - File naming: `$org-$repo-$branch.yaml` (only `.yaml`, not `.yml`)
   - Required fields: `build_root`, `images`/`tests`/`promotion` as needed
   - Test definitions: Must have `as:` and `workflow:` or `steps:`
   - Step-registry references: Must exist (use `/step-finder` to find)

5. **Validation Commands**:
   ```bash
   make checkconfig          # Validate all
   make update               # Validate and regenerate
   make validate-step-registry
   ```

## Important

- **Read the actual config files** - don't guess their contents
- **Check file naming** against directory structure
- **Validate YAML syntax** first before checking structure
- **Verify step-registry references** exist
- **Provide specific fix instructions** for each issue
- **Reference documentation** when appropriate

## Example Output

```
## Validation Results

✅ Passed: File naming, YAML syntax, structure
⚠️ Warnings: Workflow "ipi-aws-old" may be deprecated - use `/step-finder`
❌ Errors: 
  - Invalid step reference "openshift-e2e-test-old" - use `/step-finder`
  - Missing `build_root` - add build_root section
📝 Recommendations: Use multi-stage workflows, add documentation
```

Now validate the configuration at: "{{config_path}}"

