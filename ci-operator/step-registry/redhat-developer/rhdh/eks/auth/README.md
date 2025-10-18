# RHDH EKS Authentication Functions

This directory contains EKS-specific authentication functions for RHDH CI scripts.

## Usage

To use these functions in your CI scripts, source the EKS auth functions step:

```bash
# Source common functions first
source /ci-operator/step-registry/redhat-developer/rhdh/common/redhat-developer-rhdh-common-commands.sh

# Source EKS-specific functions
source /ci-operator/step-registry/redhat-developer/rhdh/eks/auth/redhat-developer-rhdh-eks-auth-commands.sh

# Now you can use any of the available functions
authenticate_eks "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" "$AWS_REGION" "$KUBECONFIG_PATH"
setup_eks_env
setup_eks_namespace
```

## Available Functions

### EKS Authentication
- `authenticate_eks([access_key_id], [secret_access_key], [region], [kubeconfig_path])` - Authenticate with AWS and configure EKS

### EKS Environment Setup
- `setup_eks_env()` - Setup EKS platform environment variables
- `setup_eks_namespace([namespace], [rbac_namespace])` - Setup EKS namespace configuration

### Complete Workflow
- `run_eks_workflow([access_key_id], [secret_access_key], [region], [kubeconfig_path])` - Complete EKS workflow using common functions

## Example Integration

Here's how you can refactor an existing EKS script to use these functions:

### Before (Original Script)
```bash
#!/bin/bash
echo "========== Cluster Authentication =========="
AWS_ACCESS_KEY_ID=$(cat /tmp/secrets/AWS_ACCESS_KEY_ID)
AWS_SECRET_ACCESS_KEY=$(cat /tmp/secrets/AWS_SECRET_ACCESS_KEY)
AWS_DEFAULT_REGION=$(cat /tmp/secrets/AWS_DEFAULT_REGION)
# ... lots of AWS setup code ...
```

### After (Using Modular Functions)
```bash
#!/bin/bash
# Source common functions
source /ci-operator/step-registry/redhat-developer/rhdh/common/redhat-developer-rhdh-common-commands.sh

# Source EKS-specific functions
source /ci-operator/step-registry/redhat-developer/rhdh/eks/auth/redhat-developer-rhdh-eks-auth-commands.sh

# Use functions
authenticate_eks "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" "$AWS_REGION" "$KUBECONFIG_PATH"
setup_service_account_token
setup_eks_env
setup_git_repository
execute_tests
```

## Function Parameters

### authenticate_eks()
- `access_key_id`: AWS access key ID
- `secret_access_key`: AWS secret access key  
- `region`: AWS region
- `kubeconfig_path`: Path to kubeconfig file

### setup_eks_namespace()
- `namespace`: Kubernetes namespace (default: "showcase-k8s-ci-nightly")
- `rbac_namespace`: RBAC namespace (default: "showcase-rbac-k8s-ci-nightly")

## Benefits

1. **Code Reuse**: Eliminates duplication across EKS CI scripts
2. **Maintainability**: Update EKS functions in one place to fix issues everywhere
3. **Consistency**: Ensures all EKS scripts follow the same patterns
4. **Modularity**: Can mix and match with common functions
5. **Testing**: Easier to test individual EKS functions in isolation

## Integration with Common Functions

This EKS auth step is designed to work seamlessly with the common functions step:

```bash
# Complete workflow example
source /ci-operator/step-registry/redhat-developer/rhdh/common/redhat-developer-rhdh-common-commands.sh
source /ci-operator/step-registry/redhat-developer/rhdh/eks/auth/redhat-developer-rhdh-eks-auth-commands.sh

# Use both common and EKS-specific functions
setup_workdir
authenticate_eks "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" "$AWS_REGION" "$KUBECONFIG_PATH"
setup_service_account_token
setup_eks_env
setup_git_repository
handle_pr_branch
analyze_changeset
resolve_image_tag
setup_eks_namespace
execute_tests
```
