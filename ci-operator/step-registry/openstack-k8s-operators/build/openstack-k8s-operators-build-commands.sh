#!/usr/bin/env bash

set -ex

ORG="openstack-k8s-operators"
META_OPERATOR="openstack-operator"
BASE_DIR=${HOME:-"/alabama"}

# We don't want to use OpenShift-CI build cluster namespace
unset NAMESPACE

# Check org and project from job's spec
REF_REPO=$(echo ${JOB_SPEC} | jq -r '.refs.repo')
REF_ORG=$(echo ${JOB_SPEC} | jq -r '.refs.org')
# PR SHA
PR_SHA=$(echo ${JOB_SPEC} | jq -r '.refs.pulls[0].sha')
# Get Pull request info - Pull request
PR_NUMBER=$(echo ${JOB_SPEC} | jq -r '.refs.pulls[0].number')
PR_REPO_NAME=$(curl -s  -X GET -H \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    https://api.github.com/repos/${REF_ORG}/${REF_REPO}/pulls/${PR_NUMBER} | \
    jq -r  '.head.repo.full_name')

# Fails if step is not being used on openstack-k8s-operators repos
# Gets base repo name
BASE_OP=${REF_REPO}
IS_REHEARSAL=false
if [[ "$REF_ORG" != "$ORG" ]]; then
    echo "Not a ${ORG} job. Checking if isn't a rehearsal job..."
    EXTRA_REF_REPO=$(echo ${JOB_SPEC} | jq -r '.extra_refs[0].repo')
    EXTRA_REF_ORG=$(echo ${JOB_SPEC} | jq -r '.extra_refs[0].org')
    #EXTRA_REF_BASE_REF=$(echo ${JOB_SPEC} | jq -r '.extra_refs[0].base_ref')
    if [[ "$EXTRA_REF_ORG" != "$ORG" ]]; then
      echo "Failing since this step supports only ${ORG} changes."
      exit 1
    fi
    IS_REHEARSAL=true
    BASE_OP=${EXTRA_REF_REPO}
fi
SERVICE_NAME=$(echo "${BASE_OP}" | sed 's/\(.*\)-operator/\1/')

function create_openstack_namespace {
  pushd ${BASE_DIR}
  if [ ! -d "./install_yamls" ]; then
    git clone https://github.com/openstack-k8s-operators/install_yamls.git
  fi
  cd install_yamls
  make namespace
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
  export BUNDLE_STORAGE_IMG=${IMAGE_TAG_BASE}-storage-bundle:${IMAGE_TAG}

  unset GOFLAGS
  pushd ${OP_DIR}
  GOWORK='' make build bundle

  # Build and push operator image
  oc new-build --binary --strategy=docker --name ${OPERATOR} --to=${IMAGE_TAG_BASE}:${IMAGE_TAG} --push-secret=${REGISTRY_SECRET} --to-docker=true
  oc set build-secret --pull bc/${OPERATOR} ${DOCKER_REGISTRY_SECRET}
  oc start-build ${OPERATOR} --from-dir . -F

  # if it is the metaoperator and any extra dependant bundles exist build and push them here
  local STORAGE_BUNDLE_EXISTS=0
  if [[ -f storage-bundle.Dockerfile ]]; then
    DOCKERFILE=storage-bundle.Dockerfile /bin/bash hack/pin-custom-bundle-dockerfile.sh
    oc new-build --binary --strategy=docker --name ${OPERATOR}-storage-bundle --to=${IMAGE_TAG_BASE}-storage-bundle:${IMAGE_TAG} --push-secret=${REGISTRY_SECRET} --to-docker=true
    DOCKERFILE_PATH_PATCH=(\{\"spec\":\{\"strategy\":\{\"dockerStrategy\":\{\"dockerfilePath\":\"storage-bundle.Dockerfile.pinned\"\}\}\}\})
    oc patch bc ${OPERATOR}-storage-bundle -p "${DOCKERFILE_PATH_PATCH[@]}"
    oc start-build ${OPERATOR}-storage-bundle --from-dir . -F
    STORAGE_BUNDLE_EXISTS=1
  fi

  # Build and push bundle image
  oc new-build --binary --strategy=docker --name ${OPERATOR}-bundle --to=${IMAGE_TAG_BASE}-bundle:${IMAGE_TAG} --push-secret=${REGISTRY_SECRET} --to-docker=true

  if [[ "$OPERATOR" == "$META_OPERATOR" ]]; then
    DOCKERFILE="custom-bundle.Dockerfile.pinned"
  else
    DOCKERFILE="bundle.Dockerfile"
  fi
  DOCKERFILE_PATH_PATCH=(\{\"spec\":\{\"strategy\":\{\"dockerStrategy\":\{\"dockerfilePath\":\""${DOCKERFILE}"\"\}\}\}\})

  oc patch bc ${OPERATOR}-bundle -p "${DOCKERFILE_PATH_PATCH[@]}"
  oc start-build ${OPERATOR}-bundle --from-dir . -F

  BASE_BUNDLE=${IMAGE_TAG_BASE}-bundle:${IMAGE_TAG}
  DOCKERFILE="index.Dockerfile"
  DOCKERFILE_PATH_PATCH=(\{\"spec\":\{\"strategy\":\{\"dockerStrategy\":\{\"dockerfilePath\":\""${DOCKERFILE}"\"\}\}\}\})

# todo: Improve include manila bundle workflow. For meta operaor only we need to add manila bundle in index and not for individual operators like keystone.
  if [[ "$OPERATOR" == "$META_OPERATOR" ]]; then
    if [[ "$STORAGE_BUNDLE_EXISTS" == "1" ]]; then
      opm index add --bundles "${BASE_BUNDLE}",${IMAGE_TAG_BASE}-storage-bundle:${IMAGE_TAG} --out-dockerfile "${DOCKERFILE}" --generate
    else
      # FIXME: we can drop manila here once ${IMAGE_TAG_BASE}-storage-bundle:${IMAGE_TAG} lands
      opm index add --bundles "${BASE_BUNDLE}",quay.io/openstack-k8s-operators/manila-operator-bundle:latest --out-dockerfile "${DOCKERFILE}" --generate
    fi
  else
    opm index add --bundles "${BASE_BUNDLE}" --out-dockerfile "${DOCKERFILE}" --generate
  fi

  oc new-build --binary --strategy=docker --name ${OPERATOR}-index --to=${IMAGE_TAG_BASE}-index:${IMAGE_TAG} --push-secret=${REGISTRY_SECRET} --to-docker=true
  oc patch bc ${OPERATOR}-index -p "${DOCKERFILE_PATH_PATCH[@]}"
  oc start-build ${OPERATOR}-index --from-dir . -F

  popd
}

# Begin operators build
# Copy base operator code to base directory
cp -r /go/src/github.com/${ORG}/${BASE_OP}/ ${BASE_DIR}

# Create and enable openstack namespace
create_openstack_namespace

# Secret for pulling containers from docker.io
DOCKER_REGISTRY_SECRET=pull-docker-secret
oc create secret generic ${DOCKER_REGISTRY_SECRET} --from-file=.dockerconfigjson=/secrets/docker/config.json --type=kubernetes.io/dockerconfigjson

# Secret for pushing containers - openstack namespace
REGISTRY_SECRET=push-quay-secret
oc create secret generic ${REGISTRY_SECRET} --from-file=.dockerconfigjson=/secrets/rdoquay/config.json --type=kubernetes.io/dockerconfigjson

# Build operator
IMAGE_TAG_BASE=${REGISTRY}/${ORGANIZATION}/${BASE_OP}
build_push_operator_images "${BASE_OP}" "${BASE_DIR}/${BASE_OP}" "${IMAGE_TAG_BASE}" "${PR_SHA}"

# If operator being tested is not meta-operator, we need to build openstack-operator
if [[ "$BASE_OP" != "$META_OPERATOR" ]]; then
  pushd ${BASE_DIR}
  if [ ! -d "./openstack-operator" ]; then
    git clone https://github.com/openstack-k8s-operators/openstack-operator.git
  fi
  pushd openstack-operator

  # If is rehearsal job, we need to point to $ORG repo and commit
  if [[ "$IS_REHEARSAL" == true ]]; then
    pushd ${BASE_DIR}/${BASE_OP}
    API_SHA=$(git log -n 1 --pretty=format:"%H")
    popd
    REPO_NAME="${ORG}/${BASE_OP}"
  else
    API_SHA=${PR_SHA}
    REPO_NAME=${PR_REPO_NAME}
    # NOTE(dviroel): We need to replace registry in bundle only when testing
    #  a PR against operator's repo. When testing rehearsal jobs, we consume
    #  from latest commit.
    export IMAGENAMESPACE=${ORGANIZATION}
    export IMAGEREGISTRY=${REGISTRY}
    export IMAGEBASE=${SERVICE_NAME}
  fi

  go mod edit -replace github.com/${ORG}/${BASE_OP}/api=github.com/${REPO_NAME}/api@${API_SHA}
  go mod tidy
  pushd ./apis/
  go mod edit -replace github.com/${ORG}/${BASE_OP}/api=github.com/${REPO_NAME}/api@${API_SHA}
  go mod tidy
  popd

  # Build openstack-operator bundle and index
  IMAGE_TAG_BASE=${REGISTRY}/${ORGANIZATION}/${META_OPERATOR}
  build_push_operator_images "${META_OPERATOR}" "${BASE_DIR}/${META_OPERATOR}" "${IMAGE_TAG_BASE}" "${PR_SHA}"

  popd
  popd
fi
