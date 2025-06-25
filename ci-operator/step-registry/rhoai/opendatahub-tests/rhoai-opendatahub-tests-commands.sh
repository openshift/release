#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

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

# Execute the clone and apply function (unless skipped)
if [ "${SKIP_ODH_MODEL_CONTROLLER_DEPLOY}" = "true" ]; then
  echo "Skipping odh-model-controller deployment as SKIP_ODH_MODEL_CONTROLLER_DEPLOY is set to true"
else
  clone_and_apply_odh_model_controller
fi

if [ "${SET_AWS_ENV_VARS}" = "true" ]; then
  AWS_ACCESS_KEY_ID=$(grep "aws_access_key_id="  "${CLUSTER_PROFILE_DIR}/.awscred" | cut -d '=' -f2)
  AWS_SECRET_ACCESS_KEY=$(grep "aws_secret_access_key="  "${CLUSTER_PROFILE_DIR}/.awscred" | cut -d '=' -f2)
  BUCKET_INFO="/tmp/secrets/ci"
  CI_S3_BUCKET_NAME="$(cat ${BUCKET_INFO}/CI_S3_BUCKET_NAME)"
  MODELS_S3_BUCKET_NAME="$(cat ${BUCKET_INFO}/MODELS_S3_BUCKET_NAME)"

  export AWS_SECRET_ACCESS_KEY
  export AWS_ACCESS_KEY_ID
  export CI_S3_BUCKET_NAME
  export CI_S3_BUCKET_REGION="us-east-1"
  export CI_S3_BUCKET_ENDPOINT="https://s3.us-east-1.amazonaws.com/"
  export MODELS_S3_BUCKET_NAME
  export MODELS_S3_BUCKET_REGION="us-east-2"
  export MODELS_S3_BUCKET_ENDPOINT="https://s3.us-east-2.amazonaws.com/"
fi

export KUBECONFIG=${SHARED_DIR}/kubeconfig
#TEMP
sleep 2h # Wait for the cluster to be ready

RUN_COMMAND="uv run pytest -m smoke tests/model_serving/model_server \
            --tc=use_unprivileged_client:False \
            -s -o log_cli=true \
            --junit-xml=${ARTIFACT_DIR}/xunit_results.xml \
            --log-file=${ARTIFACT_DIR}/pytest-tests.log"

if [ "${SKIP_CLUSTER_SANITY_CHECK}" = "true" ]; then
  RUN_COMMAND+=" --cluster-sanity-skip-check "
fi

if [ "${SKIP_RHOAI_SANITY_CHECK}" = "true" ]; then
  RUN_COMMAND+=" --cluster-sanity-skip-rhoai-check "
fi

if [ -n "${TEST_MARKERS}" ]; then
    RUN_COMMAND+=" -m ${TEST_MARKERS} "
fi

if [ -n "${TEST_SELECTORS}" ]; then
    RUN_COMMAND+=" -k ${TEST_SELECTORS} "
fi

echo "$RUN_COMMAND"

${RUN_COMMAND}