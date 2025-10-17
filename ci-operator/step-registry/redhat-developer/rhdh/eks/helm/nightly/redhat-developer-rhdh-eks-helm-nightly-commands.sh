#!/bin/bash
# Source common functions
source /ci-operator/step-registry/redhat-developer/rhdh/common/redhat-developer-rhdh-common-commands.sh

# Source EKS-specific functions
source /ci-operator/step-registry/redhat-developer/rhdh/eks/auth/redhat-developer-rhdh-eks-auth-commands.sh

# Use the functions
authenticate_eks "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" "$AWS_REGION" "$KUBECONFIG_PATH"
setup_service_account_token
setup_eks_env
setup_git_repository
execute_tests