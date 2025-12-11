#!/bin/bash
echo "========== Workdir Setup =========="
export HOME WORKSPACE
HOME=/tmp
WORKSPACE=$(pwd)
cd /tmp || exit

echo "========== Cluster Authentication =========="
AWS_ACCESS_KEY_ID=$(cat /tmp/secrets/AWS_ACCESS_KEY_ID)
AWS_SECRET_ACCESS_KEY=$(cat /tmp/secrets/AWS_SECRET_ACCESS_KEY)
AWS_DEFAULT_REGION=$(cat /tmp/secrets/AWS_DEFAULT_REGION)
AWS_REGION=$AWS_DEFAULT_REGION
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION AWS_REGION
aws configure set aws_access_key_id "${AWS_ACCESS_KEY_ID}"
aws configure set aws_secret_access_key "${AWS_SECRET_ACCESS_KEY}"
aws configure set default.region "${AWS_DEFAULT_REGION}"

echo "Verifying kubeconfig file from Mapt exists in SHARED_DIR..."
if [[ ! -f "${SHARED_DIR}/kubeconfig" ]]; then
  echo "Error: kubeconfig file not found at ${SHARED_DIR}/kubeconfig"
  exit 1
fi

echo "Setting kubeconfig permissions..."
if ! chmod 600 "${SHARED_DIR}/kubeconfig"; then
  echo "Error: Failed to set kubeconfig permissions"
  exit 1
fi

echo "Setting KUBECONFIG environment variable..."
KUBECONFIG="${SHARED_DIR}/kubeconfig"
export KUBECONFIG

echo "Verifying kubeconfig file..."
if ! kubectl config view > /dev/null 2>&1; then
  echo "Error: Invalid kubeconfig file"
  exit 1
fi

echo "Verifying cluster connectivity..."
if ! kubectl cluster-info > /dev/null 2>&1; then
  echo "Error: Cannot connect to cluster."
  exit 1
fi

echo "========== Cluster Service Account and Token Management =========="
# Create a service account and assign cluster url and token
sa_namespace="default"
sa_name="tester-sa-2"
sa_binding_name="${sa_name}-binding"
sa_secret_name="${sa_name}-secret"

if token="$(kubectl get secret ${sa_secret_name} -n ${sa_namespace} -o jsonpath='{.data.token}' 2>/dev/null)"; then
  K8S_CLUSTER_TOKEN=$(echo "${token}" | base64 --decode)
  echo "Acquired existing token for the service account into K8S_CLUSTER_TOKEN"
else
  echo "Creating service account"
  if ! kubectl get serviceaccount ${sa_name} -n ${sa_namespace} &> /dev/null; then
    echo "Creating service account ${sa_name}..."
    kubectl create serviceaccount ${sa_name} -n ${sa_namespace}
    echo "Creating cluster role binding..."
    kubectl create clusterrolebinding ${sa_binding_name} \
        --clusterrole=cluster-admin \
        --serviceaccount=${sa_namespace}:${sa_name}
    echo "Service account and binding created successfully"
  else
    echo "Service account ${sa_name} already exists in namespace ${sa_namespace}"
  fi
  echo "Creating secret for service account"
  kubectl apply --namespace="${sa_namespace}" -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${sa_secret_name}
  namespace: ${sa_namespace}
  annotations:
    kubernetes.io/service-account.name: ${sa_name}
type: kubernetes.io/service-account-token
EOF

  retries=12
  sleep_time=5
  for ((i=1; i <= retries; i++)); do
    if token="$(kubectl get secret ${sa_secret_name} -n ${sa_namespace} -o jsonpath='{.data.token}' 2>/dev/null)"; then
      echo "Successfully got token on attempt $i."
      break
    elif [ $i -eq $retries ]; then
      echo "Failed to get token after $i attempts. Exiting..."
      exit 1
    else
      echo "Failed to get token on attempt $i, retrying..."
    fi
    sleep $sleep_time
  done
  K8S_CLUSTER_TOKEN=$(echo "${token}" | base64 --decode)
  echo "Acquired token for the service account into K8S_CLUSTER_TOKEN"
fi
K8S_CLUSTER_URL=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
export K8S_CLUSTER_TOKEN K8S_CLUSTER_URL

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

echo "========== Git Repository Setup & Checkout =========="
# Prepare to git checkout
export GIT_PR_NUMBER GITHUB_ORG_NAME GITHUB_REPOSITORY_NAME TAG_NAME
GIT_PR_NUMBER=$(echo "${JOB_SPEC}" | jq -r '.refs.pulls[0].number')
echo "GIT_PR_NUMBER : $GIT_PR_NUMBER"
GITHUB_ORG_NAME="redhat-developer"
GITHUB_REPOSITORY_NAME="rhdh"

export QUAY_REPO RELEASE_BRANCH_NAME
QUAY_REPO="rhdh-community/rhdh"
# Get the base branch name based on job.
RELEASE_BRANCH_NAME=$(echo ${JOB_SPEC} | jq -r '.extra_refs[].base_ref' 2>/dev/null || echo ${JOB_SPEC} | jq -r '.refs.base_ref')

# Clone and checkout the specific PR
git clone "https://github.com/${GITHUB_ORG_NAME}/${GITHUB_REPOSITORY_NAME}.git"
cd "${GITHUB_REPOSITORY_NAME}" || exit
git checkout "$RELEASE_BRANCH_NAME" || exit

git config --global user.name "rhdh-qe"
git config --global user.email "rhdh-qe@redhat.com"

echo "========== PR Branch Handling =========="
if [ "$JOB_TYPE" == "presubmit" ] && [[ "$JOB_NAME" != rehearse-* ]]; then
    # If executed as PR check of the repository, switch to PR branch.
    git fetch origin pull/"${GIT_PR_NUMBER}"/head:PR"${GIT_PR_NUMBER}"
    git checkout PR"${GIT_PR_NUMBER}"
    git merge origin/$RELEASE_BRANCH_NAME --no-edit
    GIT_PR_RESPONSE=$(curl -s "https://api.github.com/repos/${GITHUB_ORG_NAME}/${GITHUB_REPOSITORY_NAME}/pulls/${GIT_PR_NUMBER}")
    LONG_SHA=$(echo "$GIT_PR_RESPONSE" | jq -r '.head.sha')
    SHORT_SHA=$(git rev-parse --short=8 ${LONG_SHA})
    TAG_NAME="pr-${GIT_PR_NUMBER}-${SHORT_SHA}"
    echo "TAG_NAME: $TAG_NAME"
    IMAGE_NAME="${QUAY_REPO}:${TAG_NAME}"
    echo "IMAGE_NAME: $IMAGE_NAME"
fi

echo "========== Changeset Analysis =========="
PR_CHANGESET=$(git diff --name-only $RELEASE_BRANCH_NAME)
echo "Changeset: $PR_CHANGESET"

# Check if changes are exclusively within the specified directories
DIRECTORIES_TO_CHECK=".ibm|e2e-tests|docs|.claude|.cursor|.rulesync|.vscode"
ONLY_IN_DIRS=true

for change in $PR_CHANGESET; do
    # Check if the change is not within the specified directories
    if ! echo "$change" | grep -qE "^($DIRECTORIES_TO_CHECK)/"; then
        ONLY_IN_DIRS=false
        break
    fi
done

echo "ONLY_IN_DIRS: $ONLY_IN_DIRS"

echo "========== Image Tag Resolution =========="
if [[ "$JOB_NAME" == rehearse-* || "$JOB_TYPE" == "periodic" ]]; then
    QUAY_REPO="rhdh/rhdh-hub-rhel9"
    if [ "${RELEASE_BRANCH_NAME}" != "main" ]; then
        # Get branch a specific tag name (e.g., 'release-1.5' becomes '1.5')
        TAG_NAME="$(echo $RELEASE_BRANCH_NAME | cut -d'-' -f2)"
    else
        TAG_NAME="next"
    fi
    echo "TAG_NAME: $TAG_NAME"
elif [[ "$ONLY_IN_DIRS" == "true" && "$JOB_TYPE" == "presubmit" ]];then
    if [ "${RELEASE_BRANCH_NAME}" != "main" ]; then
        QUAY_REPO="rhdh/rhdh-hub-rhel9"
        # Get branch a specific tag name (e.g., 'release-1.5' becomes '1.5')
        TAG_NAME="$(echo $RELEASE_BRANCH_NAME | cut -d'-' -f2)"
    else
        QUAY_REPO="rhdh-community/rhdh"
        TAG_NAME="next"
    fi
    echo "INFO: Bypassing PR image build wait, using tag: ${TAG_NAME}"
    echo "INFO: Container image will be tagged as: ${QUAY_REPO}:${TAG_NAME}"
else
    # Timeout configuration for waiting for Docker image availability
    MAX_WAIT_TIME_SECONDS=$((60*60))    # Maximum wait time in minutes * seconds
    POLL_INTERVAL_SECONDS=60      # Check every 60 seconds

    ELAPSED_TIME=0

    while true; do
        # Check image availability
        response=$(curl -s "https://quay.io/api/v1/repository/${QUAY_REPO}/tag/?specificTag=$TAG_NAME")

        # Use jq to parse the JSON and see if the tag exists
        tag_count=$(echo $response | jq '.tags | length')

        if [ "$tag_count" -gt "0" ]; then
            echo "Docker image $IMAGE_NAME is now available. Time elapsed: $(($ELAPSED_TIME / 60)) minute(s)."
            break
        fi

        # Wait for the interval duration
        sleep $POLL_INTERVAL_SECONDS

        # Increment the elapsed time
        ELAPSED_TIME=$(($ELAPSED_TIME + $POLL_INTERVAL_SECONDS))

        # If the elapsed time exceeds the timeout, exit with an error
        if [ $ELAPSED_TIME -ge $MAX_WAIT_TIME_SECONDS ]; then
            echo "Timed out waiting for Docker image $IMAGE_NAME. Time elapsed: $(($ELAPSED_TIME / 60)) minute(s)."
            exit 1
        fi
    done
fi

echo "========== Current branch =========="
echo "Current branch: $(git branch --show-current)"
echo "Using Image: ${QUAY_REPO}:${TAG_NAME}"

echo "========== Test Execution =========="
echo "Executing openshift-ci-tests.sh"
bash ./.ibm/pipelines/openshift-ci-tests.sh
