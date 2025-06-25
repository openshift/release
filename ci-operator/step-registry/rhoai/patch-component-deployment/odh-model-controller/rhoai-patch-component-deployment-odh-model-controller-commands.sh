#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

namespace="redhat-ods-applications"

# Clone odh-model-controller repository and apply kustomize manifests
clone_and_apply_odh_model_controller() {
  echo "=== Cloning and applying odh-model-controller manifests ==="
  
  # Set up working directory
  WORK_DIR="/tmp/odh-model-controller-clone"
  mkdir -p "$WORK_DIR"
  cd "$WORK_DIR"
  
  # Determine branch to clone from
  # Use standard Prow environment variables to get the correct branch
  if [ -n "${PULL_BASE_REF:-}" ]; then
    BRANCH="${PULL_BASE_REF}"
    echo "Using PULL_BASE_REF branch: $BRANCH"
  elif [ -n "${PULL_PULL_REF:-}" ]; then
    BRANCH="${PULL_PULL_REF}"
    echo "Using PULL_PULL_REF branch: $BRANCH"
  else
    # Default to main if no PR info available
    BRANCH="main"
    echo "Using default branch: $BRANCH"
  fi
  
  # Check if git is available
  if ! command -v git &> /dev/null; then
    echo "git not found, installing..."
    # Install git
    if command -v yum &> /dev/null; then
      yum install -y git
    elif command -v apt-get &> /dev/null; then
      apt-get update && apt-get install -y git
    elif command -v apk &> /dev/null; then
      apk add --no-cache git
    else
      echo "ERROR: Unable to install git - no known package manager found"
      return 1
    fi
  fi
  
  # Repository URL
  REPO_URL="https://github.com/opendatahub-io/odh-model-controller.git"
  
  echo "Cloning odh-model-controller from $REPO_URL, branch: $BRANCH"
  
  # Clone the repository
  git clone --depth 1 --branch "$BRANCH" "$REPO_URL" odh-model-controller || {
    echo "Failed to clone branch $BRANCH, trying main branch"
    git clone --depth 1 --branch main "$REPO_URL" odh-model-controller
  }
  
  cd odh-model-controller
  
  # Check if kustomize is available
  if ! command -v kustomize &> /dev/null; then
    echo "kustomize not found, installing..."
    # Install kustomize
    curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash
    sudo mv kustomize /usr/local/bin/
  fi
  
  # Check if config/default directory exists
  if [ ! -d "config/default" ]; then
    echo "ERROR: config/default directory not found in odh-model-controller repository"
    echo "Available directories:"
    ls -la
    return 1
  fi
  
  echo "Building kustomize configuration..."
  kustomize build config/default > install.yaml
  
  echo "Applying odh-model-controller manifests to cluster..."
  oc apply -f install.yaml
  
  echo "Waiting for odh-model-controller deployment to be ready..."
  oc wait --for=condition=available --timeout=300s deployment/odh-model-controller -n system 2>/dev/null || \
  oc wait --for=condition=available --timeout=300s deployment/odh-model-controller -n odh-model-controller-system 2>/dev/null || \
  echo "Warning: Could not wait for deployment (might not exist yet or in different namespace)"
  
  echo "=== odh-model-controller manifests applied successfully ==="
  
  # Return to original directory
  cd - > /dev/null
}

# Execute the clone and apply function first
clone_and_apply_odh_model_controller

if [ -n "${ODH_MODEL_CONTROLLER_IMAGE}" ]; then
  echo "Updating odh-model-controller deployment image to ${ODH_MODEL_CONTROLLER_IMAGE}"

  echo "Scaling RHOAI operator to 0"
  oc scale --replicas=0 deployment/rhods-operator -n redhat-ods-operator

  echo "Updating odh-model-controller deployment image to ${ODH_MODEL_CONTROLLER_IMAGE}"
  oc set image  -n ${namespace}  deployment/odh-model-controller  manager="${ODH_MODEL_CONTROLLER_IMAGE}"

  echo "Wait For Deployment Replica To Be Ready"

  # Verify all pods are running
  oc_wait_for_pods() {
      local ns="${1}"
      local pods

      for _ in {1..120}; do
          echo "Waiting for pods in '${ns}' in state Running or Completed"
          pods=$(oc get pod -n "${ns}" | grep -v "Running\|Completed" | tail -n +2)
          echo "${pods}"
          if [[ -z "${pods}" ]]; then
              echo "All pods in '${ns}' are in state Running or Completed"
              break
          fi
          sleep 20
      done
      if [[ -n "${pods}" ]]; then
          echo "ERROR: Some pods in '${ns}' are not in state Running or Completed"
          echo "${pods}"
          exit 1
      fi
  }

  oc_wait_for_pods ${namespace}

  sleep 300

  echo "odh-model-controller is patched successfully"

fi

# # adding sleep for debug 2h
# echo "sleeping for 2h now for debug"
# sleep 2h