#!/bin/bash
# EKS Authentication Functions
# This step provides EKS-specific authentication functions

# Set strict error handling
set -euo pipefail

# =============================================================================
# EKS AUTHENTICATION FUNCTIONS
# =============================================================================

# Authenticate with AWS and configure EKS
# Usage: authenticate_eks [access_key_id] [secret_access_key] [region] [kubeconfig_path]
authenticate_eks() {
    local access_key_id="${1}"
    local secret_access_key="${2}"
    local region="${3}"
    local kubeconfig_path="${4}"
    
    echo "========== Cluster Authentication =========="
    
    # Set AWS credentials
    export AWS_ACCESS_KEY_ID="${access_key_id}"
    export AWS_SECRET_ACCESS_KEY="${secret_access_key}"
    export AWS_DEFAULT_REGION="${region}"
    export AWS_REGION="${region}"
    
    # Configure AWS CLI
    aws configure set aws_access_key_id "${access_key_id}"
    aws configure set aws_secret_access_key "${secret_access_key}"
    aws configure set default.region "${region}"

    # Use kubeconfig from mapt
    chmod 600 "${kubeconfig_path}"
    KUBECONFIG="${kubeconfig_path}"
    export KUBECONFIG
}

# Setup EKS platform environment variables
# Usage: setup_eks_env
setup_eks_env() {
    echo "========== Platform Environment Variables =========="
    echo "Setting platform environment variables:"
    export IS_OPENSHIFT="false"
    echo "IS_OPENSHIFT=${IS_OPENSHIFT}"
    export CONTAINER_PLATFORM="eks"
    echo "CONTAINER_PLATFORM=${CONTAINER_PLATFORM}"
    echo "Getting container platform version"
    CONTAINER_PLATFORM_VERSION=$(kubectl version --output json 2> /dev/null | jq -r '.serverVersion.major + "." + .serverVersion.minor' || echo "unknown")
    export CONTAINER_PLATFORM_VERSION
    echo "CONTAINER_PLATFORM_VERSION=${CONTAINER_PLATFORM_VERSION}"
}

# Setup EKS namespace configuration
# Usage: setup_eks_namespace [namespace] [rbac_namespace]
setup_eks_namespace() {
    local namespace="${1:-showcase-k8s-ci-nightly}"
    local rbac_namespace="${2:-showcase-rbac-k8s-ci-nightly}"
    
    echo "========== Namespace Configuration =========="
    NAME_SPACE="${namespace}"
    NAME_SPACE_RBAC="${rbac_namespace}"
    export NAME_SPACE NAME_SPACE_RBAC
    echo "NAME_SPACE: $NAME_SPACE"
    echo "NAME_SPACE_RBAC: $NAME_SPACE_RBAC"
}

# Complete EKS workflow using common functions
# Usage: run_eks_workflow [access_key_id] [secret_access_key] [region] [kubeconfig_path]
run_eks_workflow() {
    local access_key_id="${1}"
    local secret_access_key="${2}"
    local region="${3}"
    local kubeconfig_path="${4}"
    
    # Source common functions
    # shellcheck disable=SC1091
    source /ci-operator/step-registry/redhat-developer/rhdh/common/redhat-developer-rhdh-common-commands.sh
    
    # Setup workdir
    setup_workdir
    
    # Authenticate with EKS
    authenticate_eks "${access_key_id}" "${secret_access_key}" "${region}" "${kubeconfig_path}"
    
    # Setup service account token
    setup_service_account_token
    
    # Setup EKS environment
    setup_eks_env
    
    # Setup git repository
    setup_git_repository
    
    # Handle PR branch
    handle_pr_branch
    
    # Analyze changeset
    analyze_changeset
    
    # Resolve image tag
    resolve_image_tag
    
    # Setup EKS namespace
    setup_eks_namespace
    
    # Execute tests
    execute_tests
}
