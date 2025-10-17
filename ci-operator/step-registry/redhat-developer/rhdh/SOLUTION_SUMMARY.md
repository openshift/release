# RHDH CI Scripts Modularization Solution

## Overview

This solution addresses the need to create reusable bash functions for Prow CI scripts by implementing a modular approach that follows Prow's step registry conventions.

## Problem Solved

The original issue was that multiple RHDH CI scripts contained duplicated code across different platforms (GKE, EKS, AKS, OpenShift). The user wanted to extract common functionality into reusable functions while maintaining compatibility with Prow's step registry system.

## Solution Architecture

### 1. Common Functions Step (`redhat-developer-rhdh-common`)

**Location**: `/ci-operator/step-registry/redhat-developer/rhdh/common/`

**Purpose**: Provides reusable functions that are common across all platforms.

**Key Functions**:
- `setup_workdir()` - Basic working directory setup
- `setup_service_account_token()` - Kubernetes service account management
- `setup_git_repository()` - Git repository setup and checkout
- `handle_pr_branch()` - PR branch handling and merging
- `analyze_changeset()` - Changeset analysis for conditional logic
- `resolve_image_tag()` - Image tag resolution based on job type
- `execute_tests()` - Test execution
- `wait_for_image()` - Wait for Docker image availability
- Utility functions for logging, validation, etc.

### 2. Platform-Specific Authentication Steps

**Example**: `redhat-developer-rhdh-gke-auth`

**Location**: `/ci-operator/step-registry/redhat-developer/rhdh/gke/auth/`

**Purpose**: Provides platform-specific authentication and environment setup functions.

**Key Functions**:
- `authenticate_gke()` - GKE authentication
- `setup_gke_env()` - GKE environment variables
- `setup_gke_namespace()` - GKE namespace configuration

## Usage Examples

### Basic Usage (Using Common Functions Only)

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

### Advanced Usage (Using Both Common and Platform-Specific Functions)

```bash
#!/bin/bash
# Source common functions
source /ci-operator/step-registry/redhat-developer/rhdh/common/redhat-developer-rhdh-common-commands.sh

# Source platform-specific functions
source /ci-operator/step-registry/redhat-developer/rhdh/gke/auth/redhat-developer-rhdh-gke-auth-commands.sh

# Use functions
setup_workdir
authenticate_gke "$SERVICE_ACCOUNT" "$KEY_FILE" "$CLUSTER" "$REGION" "$PROJECT"
setup_service_account_token
setup_gke_env
setup_git_repository
handle_pr_branch
analyze_changeset
resolve_image_tag
setup_gke_namespace
execute_tests
```

## Benefits

1. **Code Reuse**: Eliminates duplication across multiple CI scripts
2. **Maintainability**: Update functions in one place to fix issues everywhere
3. **Consistency**: Ensures all scripts follow the same patterns
4. **Prow Compatibility**: Follows Prow's step registry naming conventions
5. **Modularity**: Can mix and match common and platform-specific functions
6. **Testing**: Easier to test individual functions in isolation
7. **Documentation**: Centralized documentation for common operations

## File Structure

```
ci-operator/step-registry/redhat-developer/rhdh/
├── common/
│   ├── redhat-developer-rhdh-common-commands.sh
│   ├── redhat-developer-rhdh-common-ref.metadata.json
│   ├── redhat-developer-rhdh-common-ref.yaml
│   ├── OWNERS
│   └── README.md
├── gke/
│   ├── auth/
│   │   ├── redhat-developer-rhdh-gke-auth-commands.sh
│   │   ├── redhat-developer-rhdh-gke-auth-ref.metadata.json
│   │   ├── redhat-developer-rhdh-gke-auth-ref.yaml
│   │   └── OWNERS
│   └── helm/nightly/
│       ├── redhat-developer-rhdh-gke-helm-nightly-commands.sh (original)
│       ├── redhat-developer-rhdh-gke-helm-nightly-commands-refactored.sh (example)
│       └── redhat-developer-rhdh-gke-helm-nightly-commands-modular.sh (example)
└── ...
```

## Migration Strategy

1. **Phase 1**: Create common functions step (✅ Completed)
2. **Phase 2**: Create platform-specific authentication steps (✅ Started with GKE)
3. **Phase 3**: Refactor existing scripts to use common functions (✅ Examples provided)
4. **Phase 4**: Create similar auth steps for EKS, AKS, OpenShift
5. **Phase 5**: Update all existing scripts to use the modular approach

## Next Steps

1. **Create EKS Auth Step**: Similar to GKE auth but for AWS EKS
2. **Create AKS Auth Step**: Similar to GKE auth but for Azure AKS  
3. **Create OpenShift Auth Step**: For OpenShift-specific authentication
4. **Refactor All Scripts**: Update all existing scripts to use the modular approach
5. **Add Tests**: Create unit tests for individual functions
6. **Documentation**: Expand documentation with more examples

## Compliance with Prow Requirements

- ✅ Correct naming convention: `redhat-developer-rhdh-{step-name}-commands.sh`
- ✅ Proper metadata files: `.metadata.json` and `.yaml` files
- ✅ OWNERS files for proper code review
- ✅ Step registry structure compliance
- ✅ Resource specifications in YAML files

This solution provides a clean, maintainable, and Prow-compliant way to organize reusable bash functions for CI scripts.
