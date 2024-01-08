#!/usr/bin/env bash

set -ex

DEFAULT_ORG="openstack-k8s-operators"
META_OPERATOR="openstack-operator"
BASE_DIR=${HOME:-"/alabama"}

# We don't want to use OpenShift-CI build cluster namespace
unset NAMESPACE

# Check org and project from job's spec
REF_REPO=$(echo ${JOB_SPEC} | jq -r '.refs.repo')
REF_ORG=$(echo ${JOB_SPEC} | jq -r '.refs.org')
REF_BRANCH=$(echo ${JOB_SPEC} | jq -r '.refs.base_ref')

# PR SHA
PR_SHA=$(echo ${JOB_SPEC} | jq -r '.refs.pulls[0].sha')
# Get Pull request info - Pull request
PR_NUMBER=$(echo ${JOB_SPEC} | jq -r '.refs.pulls[0].number')
PR_REPO_NAME=$(curl -s  -X GET -H \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    https://api.github.com/repos/${REF_ORG}/${REF_REPO}/pulls/${PR_NUMBER} | \
    jq -r  '.head.repo.full_name')

DEPENDS_ON=$(curl -s  -X GET -H \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    https://api.github.com/repos/${REF_ORG}/${REF_REPO}/pulls/${PR_NUMBER} | \
    jq -r  '.body' | grep -iE "(depends-on).*(openstack-operator)" || true)

# Fails if step is not being used on openstack-k8s-operators repos
# Gets base repo name
BASE_OP=${REF_REPO}
IS_REHEARSAL=false
if [[ "$REF_ORG" != "$DEFAULT_ORG" ]]; then
    echo "Not a ${DEFAULT_ORG} job. Checking if isn't a rehearsal job..."
    EXTRA_REF_REPO=$(echo ${JOB_SPEC} | jq -r '.extra_refs[0].repo')
    EXTRA_REF_ORG=$(echo ${JOB_SPEC} | jq -r '.extra_refs[0].org')
    REF_BRANCH=$(echo ${JOB_SPEC} | jq -r '.extra_refs[0].base_ref')
    if [[ "$EXTRA_REF_ORG" != "$DEFAULT_ORG" ]]; then
      echo "Failing since this step supports only ${DEFAULT_ORG} changes."
      exit 1
    fi
    IS_REHEARSAL=true
    BASE_OP=${EXTRA_REF_REPO}
fi
SERVICE_NAME=$(echo "${BASE_OP}" | sed 's/\(.*\)-operator/\1/')
# sets default branch for install_yamls
export OPENSTACK_K8S_BRANCH=${REF_BRANCH}

function create_openstack_namespace {
  pushd ${BASE_DIR}
  if [ ! -d "./install_yamls" ]; then
    git clone https://github.com/openstack-k8s-operators/install_yamls.git -b ${REF_BRANCH}
  fi
  cd install_yamls
  make namespace
  popd
}

# Get build status
function get_build_status() {
    le_status=$(oc get builds -l buildconfig="$1" -o json | jq -r '.items[0].status.phase')
    echo $le_status
}

# Check if build didn't fail
function check_build_result {
  local build_name
  local build_status
  local n
  local nb_retries

  build_name="$1"
  # At this moment, we don't expect more than one build per build-config
  build_status=$(get_build_status "${build_name}")
  if [[ "$build_status" == "Failed" ]]; then
    echo "Build ${build_name} failed to complete. Aborting build step..."
    exit 1
  fi

  n=0
  # sleep time hardcoded to 30s. Adding + 29 to round up the result
  nb_retries=$(((BUILD_COMPLETE_TIMEOUT + 29) / 30))
  while [[ "$build_status" != "Complete" ]]; do
    n=$((n+1))
    if (( n > nb_retries )); then
      echo "Build ${build_name} failed to complete. Current status is ${build_status}. Aborting..."
      exit 1
    fi
    sleep 30
    build_status=$(get_build_status "${build_name}")
  done
}

# Clone the openstack-operator and checkout
# the requested PR
function clone_openstack_operator {
    git clone https://github.com/openstack-k8s-operators/openstack-operator.git -b ${REF_BRANCH}
    pushd openstack-operator
    local pr_num=""
    # Depends-On syntax detected in the PR description: get the PR ID
    if [[ -n $DEPENDS_ON ]]; then
        pr_num=$(echo "$DEPENDS_ON" | rev | cut -d"/" -f1 | rev)
    fi
    # make sure the PR ID we parse is a number
    if [[ "$pr_num" == ?(-)+([0-9]) ]]; then
        # checkout pr $pr_num
        git fetch origin pull/"$pr_num"/head:PR"$pr_num"
        git checkout PR"$pr_num"
    fi
    popd
}

# Builds and push operator image
function build_push_operator_images {
  OPERATOR="$1"
  OP_DIR="$2"
  IMAGE_TAG_BASE="$3"
  IMAGE_TAG="$4"

  export VERSION=0.0.1
  export IMG=${IMAGE_TAG_BASE}:${IMAGE_TAG}

  unset GOFLAGS
  pushd ${OP_DIR}

  # custom per project ENV variables
  if [ -f .prow_ci.env ]; then
    source .prow_ci.env
  fi

  GOWORK='' make build

  # Build and push operator image
  oc new-build --binary --strategy=docker --name ${OPERATOR} --to=${IMAGE_TAG_BASE}:${IMAGE_TAG} --push-secret=${PUSH_REGISTRY_SECRET} --to-docker=true
  oc set build-secret --pull bc/${OPERATOR} ${DOCKER_REGISTRY_SECRET}
  oc start-build ${OPERATOR} --from-dir . -F
  check_build_result ${OPERATOR}

  GOWORK='' make bundle

  # Build and push bundle image
  oc new-build --binary --strategy=docker --name ${OPERATOR}-bundle --to=${IMAGE_TAG_BASE}-bundle:${IMAGE_TAG} --push-secret=${PUSH_REGISTRY_SECRET} --to-docker=true

  # this sets defaults but allows BUNDLE_DOCKERFILE to be overridden via .prow_ci.env
  if [[ "$OPERATOR" == "$META_OPERATOR" ]]; then
    BUNDLE_DOCKERFILE=${BUNDLE_DOCKERFILE:-"custom-bundle.Dockerfile.pinned"}
  else
    BUNDLE_DOCKERFILE=${BUNDLE_DOCKERFILE:-"bundle.Dockerfile"}
  fi
  DOCKERFILE_PATH_PATCH=(\{\"spec\":\{\"strategy\":\{\"dockerStrategy\":\{\"dockerfilePath\":\""${BUNDLE_DOCKERFILE}"\"\}\}\}\})

  oc patch bc ${OPERATOR}-bundle -p "${DOCKERFILE_PATH_PATCH[@]}"
  oc set build-secret --pull bc/${OPERATOR}-bundle ${DOCKER_REGISTRY_SECRET}
  oc start-build ${OPERATOR}-bundle --from-dir . -F
  check_build_result ${OPERATOR}-bundle

  BASE_BUNDLE=${IMAGE_TAG_BASE}-bundle:${IMAGE_TAG}
  INDEX_DOCKERFILE="index.Dockerfile"
  DOCKERFILE_PATH_PATCH=(\{\"spec\":\{\"strategy\":\{\"dockerStrategy\":\{\"dockerfilePath\":\""${INDEX_DOCKERFILE}"\"\}\}\}\})

# todo: Improve include manila bundle workflow. For meta operaor only we need to add manila bundle in index and not for individual operators like keystone.
  if [[ "$OPERATOR" == "$META_OPERATOR" ]]; then
    local OPENSTACK_BUNDLES
    OPENSTACK_BUNDLES=$(/bin/bash hack/pin-bundle-images.sh)
    opm index add --bundles "${BASE_BUNDLE}${OPENSTACK_BUNDLES}" --out-dockerfile "${INDEX_DOCKERFILE}" --generate
  else
    opm index add --bundles "${BASE_BUNDLE}" --out-dockerfile "${INDEX_DOCKERFILE}" --generate
  fi

  oc new-build --binary --strategy=docker --name ${OPERATOR}-index --to=${IMAGE_TAG_BASE}-index:${IMAGE_TAG} --push-secret=${PUSH_REGISTRY_SECRET} --to-docker=true
  oc patch bc ${OPERATOR}-index -p "${DOCKERFILE_PATH_PATCH[@]}"
  oc start-build ${OPERATOR}-index --from-dir . -F
  check_build_result ${OPERATOR}-index

  popd
}

# Begin operators build
# Copy base operator code to base directory
cp -r /go/src/github.com/${DEFAULT_ORG}/${BASE_OP}/ ${BASE_DIR}

# Create and enable openstack namespace
create_openstack_namespace

# Secret for pulling containers from docker.io
DOCKER_REGISTRY_SECRET=pull-docker-secret
oc create secret generic ${DOCKER_REGISTRY_SECRET} --from-file=.dockerconfigjson=/secrets/docker/config.json --type=kubernetes.io/dockerconfigjson

# Auth needed by operator-sdk to pull images from internal
export XDG_RUNTIME_DIR=${BASE_DIR}
mkdir -p ${BASE_DIR}/containers
ln -ns /secrets/internal/config.json ${BASE_DIR}/containers/auth.json

# Secret for pushing containers - openstack namespace
PUSH_REGISTRY_SECRET=push-quay-secret
oc create secret generic ${PUSH_REGISTRY_SECRET} --from-file=.dockerconfigjson=/secrets/rdoquay/config.json --type=kubernetes.io/dockerconfigjson

# Build operator
IMAGE_TAG_BASE=${PUSH_REGISTRY}/${PUSH_ORGANIZATION}/${BASE_OP}
build_push_operator_images "${BASE_OP}" "${BASE_DIR}/${BASE_OP}" "${IMAGE_TAG_BASE}" "${PR_SHA}"

# If operator being tested is not meta-operator, we need to build openstack-operator
if [[ "$BASE_OP" != "$META_OPERATOR" ]]; then
  pushd ${BASE_DIR}
  if [ ! -d "./openstack-operator" ]; then
    clone_openstack_operator
  fi
  pushd openstack-operator

  # If is rehearsal job, we need to point to $DEFAULT_ORG repo and commit
  if [[ "$IS_REHEARSAL" == true ]]; then
    pushd ${BASE_DIR}/${BASE_OP}
    API_SHA=$(git log -n 1 --pretty=format:"%H")
    popd
    REPO_NAME="${DEFAULT_ORG}/${BASE_OP}"
  else
    API_SHA=${PR_SHA}
    REPO_NAME=${PR_REPO_NAME}
    # NOTE(dviroel): We need to replace registry in bundle only when testing
    #  a PR against operator's repo. When testing rehearsal jobs, we consume
    #  from latest commit.
    export IMAGENAMESPACE=${PUSH_ORGANIZATION}
    export IMAGEREGISTRY=${PUSH_REGISTRY}
    export IMAGEBASE=${SERVICE_NAME}
  fi

  # mod can be either /api or /apis
  MOD=$(grep github.com/${DEFAULT_ORG}/${BASE_OP}/api go.mod || true)
  # check if a replace directive is already present in go.mod
  REPLACE=$(grep -E "(^replace).*(${DEFAULT_ORG}/${BASE_OP}/api)" go.mod || true)
  # exec the following only if mod is present AND no replace directive has already
  # been added to go.mod
  if [[ -n "$MOD" && -z "$REPLACE" ]]; then
    API_MOD=$(basename $MOD)
    go mod edit -replace github.com/${DEFAULT_ORG}/${BASE_OP}/${API_MOD}=github.com/${REPO_NAME}/${API_MOD}@${API_SHA}
    go mod tidy
    pushd ./apis/
    go mod edit -replace github.com/${DEFAULT_ORG}/${BASE_OP}/${API_MOD}=github.com/${REPO_NAME}/${API_MOD}@${API_SHA}
    go mod tidy
    popd
  fi

  # Build openstack-operator bundle and index
  IMAGE_TAG_BASE=${PUSH_REGISTRY}/${PUSH_ORGANIZATION}/${META_OPERATOR}
  build_push_operator_images "${META_OPERATOR}" "${BASE_DIR}/${META_OPERATOR}" "${IMAGE_TAG_BASE}" "${PR_SHA}"

  popd
  popd
fi
