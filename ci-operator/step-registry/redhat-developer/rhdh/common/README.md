# RHDH Common Functions

This directory contains common utility functions that can be reused across different RHDH CI workflows.

## Usage

To use these functions in your CI scripts, source the common functions step:

```bash
# Source the common functions
source /ci-operator/step-registry/redhat-developer/rhdh/common/redhat-developer-rhdh-common-commands.sh

# Now you can use any of the available functions
setup_workdir
setup_git_repository
handle_pr_branch
analyze_changeset
resolve_image_tag
execute_tests
```

## Available Functions

### Workdir Setup
- `setup_workdir()` - Setup basic working directory and environment

### Service Account Management
- `setup_service_account_token([namespace], [service_account_name])` - Create or retrieve service account token

### Git Repository Management
- `setup_git_repository([github_org], [github_repo])` - Setup Git repository and checkout appropriate branch
- `handle_pr_branch()` - Handle PR branch checkout and merge
- `analyze_changeset([directories_pattern])` - Analyze changeset to determine if changes are only in specific directories

### Image Management
- `wait_for_image([quay_repo], [tag_name], [max_wait_minutes], [poll_interval_seconds])` - Wait for Docker image to be available
- `resolve_image_tag([platform_type])` - Resolve image tag based on job type and branch

### Test Execution
- `execute_tests()` - Execute the main test script

### Utility Functions
- `print_section([section_name])` - Print section header
- `check_required_env([var1], [var2], ...)` - Check if required environment variables are set
- `log_function_entry([function_name], [args...])` - Log function entry for debugging

## Example Integration

Here's how you can refactor an existing script to use these common functions:

### Before (Original Script)
```bash
#!/bin/bash
echo "========== Workdir Setup =========="
export HOME WORKSPACE
HOME=/tmp
WORKSPACE=$(pwd)
cd /tmp || exit

echo "========== Git Repository Setup & Checkout =========="
# ... lots of git setup code ...
```

### After (Using Common Functions)
```bash
#!/bin/bash
# Source common functions
source /ci-operator/step-registry/redhat-developer/rhdh/common/redhat-developer-rhdh-common-commands.sh

# Use common functions
setup_workdir
setup_git_repository
handle_pr_branch
analyze_changeset
resolve_image_tag
execute_tests
```

## Benefits

1. **Code Reuse**: Eliminate duplication across multiple CI scripts
2. **Maintainability**: Update functions in one place to fix issues everywhere
3. **Consistency**: Ensure all scripts follow the same patterns
4. **Testing**: Easier to test individual functions in isolation
5. **Documentation**: Centralized documentation for common operations

## Adding New Functions

When adding new functions to this common library:

1. Follow the existing naming conventions
2. Add proper documentation with usage examples
3. Include error handling and validation
4. Update this README with the new function details
5. Test the function across different platforms

## Platform-Specific Functions

For platform-specific functionality (GKE, EKS, AKS, OpenShift), consider creating separate step registry entries that can be referenced alongside these common functions.
