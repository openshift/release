#!/bin/bash
# GKE Authentication Functions
# This step provides GKE-specific authentication functions

# Set strict error handling
set -euo pipefail

# =============================================================================
# GKE AUTHENTICATION FUNCTIONS
# =============================================================================

# Authenticate with Google Cloud and get GKE credentials
# Usage: authenticate_gke [service_account_name] [key_file] [cluster_name] [region] [project]
authenticate_gke() {
    local service_account_name="${1}"
    local key_file="${2}"
    local cluster_name="${3}"
    local region="${4}"
    local project="${5}"
    
    echo "========== Cluster Authentication =========="
    echo "Setting up long-running GKE cluster..."
    
    # Set up directory for IBM pipelines
    DIR="$(pwd)/.ibm/pipelines"
    export DIR
    
    echo "Ingesting GKE secrets"
    echo "Authenticating with GKE"
    gcloud auth activate-service-account "${service_account_name}" --key-file "${key_file}"
    echo "Getting GKE credentials"
    gcloud container clusters get-credentials "${cluster_name}" --region "${region}" --project "${project}"
    echo "Getting GKE cluster URL"
    K8S_CLUSTER_URL=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
    export K8S_CLUSTER_URL
}

# Setup GKE platform environment variables
# Usage: setup_gke_env
setup_gke_env() {
    echo "========== Platform Environment Variables =========="
    echo "Setting platform environment variables:"
    export IS_OPENSHIFT="false"
    echo "IS_OPENSHIFT=${IS_OPENSHIFT}"
    export CONTAINER_PLATFORM="gke"
    echo "CONTAINER_PLATFORM=${CONTAINER_PLATFORM}"
    echo "Getting container platform version"
    CONTAINER_PLATFORM_VERSION=$(kubectl version --output json 2> /dev/null | jq -r '.serverVersion.major + "." + .serverVersion.minor' || echo "unknown")
    export CONTAINER_PLATFORM_VERSION
    echo "CONTAINER_PLATFORM_VERSION=${CONTAINER_PLATFORM_VERSION}"
}

# Setup GKE namespace configuration
# Usage: setup_gke_namespace [namespace] [rbac_namespace]
setup_gke_namespace() {
    local namespace="${1:-showcase-k8s-ci-nightly}"
    local rbac_namespace="${2:-showcase-rbac-k8s-ci-nightly}"
    
    echo "========== Namespace Configuration =========="
    NAME_SPACE="${namespace}"
    NAME_SPACE_RBAC="${rbac_namespace}"
    export NAME_SPACE NAME_SPACE_RBAC
    echo "NAME_SPACE: $NAME_SPACE"
    echo "NAME_SPACE_RBAC: $NAME_SPACE_RBAC"
}
