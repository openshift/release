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
# Prow build id
PROW_BUILD=$(echo ${JOB_SPEC} | jq -r '.buildid')

# PR SHA
PR_SHA=$(echo ${JOB_SPEC} | jq -r '.refs.pulls[0].sha')
# Get Pull request info - Pull request
PR_NUMBER=$(echo ${JOB_SPEC} | jq -r '.refs.pulls[0].number')
PR_REPO_NAME=$(curl -s -X GET -H \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  https://api.github.com/repos/${REF_ORG}/${REF_REPO}/pulls/${PR_NUMBER} |
  jq -r '.head.repo.full_name')

PR_BODY=$(curl -s -X GET -H \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  https://api.github.com/repos/${REF_ORG}/${REF_REPO}/pulls/${PR_NUMBER} |
  jq -r '.body')

DEPENDS_ON=$(echo "$PR_BODY" | grep -iE "(depends-on).*(openstack-operator)" || true)
DEPENDS_ON_INSTALL_YAMLS=$(echo "$PR_BODY" | grep -iE "(depends-on).*(install_yamls)" || true)

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
  local pr_num=""
  # Depends-On syntax detected in the PR description: get the PR ID
  if [[ -n $DEPENDS_ON_INSTALL_YAMLS ]]; then
    pr_num=$(echo "$DEPENDS_ON_INSTALL_YAMLS" | rev | cut -d"/" -f1 | rev | tr -d '[:space:]')
  fi
  # make sure the PR ID we parse is a number
  if [[ "$pr_num" == ?(-)+([0-9]) ]]; then
    # checkout pr $pr_num
    git fetch origin pull/"$pr_num"/head:PR"$pr_num"
    git checkout PR"$pr_num"
  fi
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
    n=$((n + 1))
    if ((n > nb_retries)); then
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
    pr_num=$(echo "$DEPENDS_ON" | rev | cut -d"/" -f1 | rev | tr -d '[:space:]')
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

  export IMG=${IMAGE_TAG_BASE}:${IMAGE_TAG}

  # Service operators ship a single-version, install-only index.
  export VERSION=0.0.1
  unset REPLACES

  unset GOFLAGS
  pushd ${OP_DIR}

  # custom per project ENV variables
  # (may override OPENSTACK_IMG_BASE_RELEASE, so source before deriving the edge)
  if [ -f .prow_ci.env ]; then
    source .prow_ci.env
  fi

  # For the meta operator, build a two-version (base -> PR) index so kuttl can
  # exercise a real OLM update. The base release index (lower edge) is set via
  # the OPENSTACK_IMG_BASE_RELEASE step env / the operator's .prow_ci.env, never
  # hardcoded here. The PR bundle uses the operator's own Makefile major.minor
  # with a .99 patch (e.g. 19.0.0 -> 19.0.99): a recognizable version that always
  # sorts above real z-stream releases of that minor, so any same-minor base
  # (up to and including the main index) yields a valid replaces edge. The build
  # fails below if the base already is that .99 version (nothing to upgrade).
  if [[ "$OPERATOR" == "$META_OPERATOR" ]]; then
    if [[ -z "${OPENSTACK_IMG_BASE_RELEASE:-}" ]]; then
      echo "OPENSTACK_IMG_BASE_RELEASE must be set (step env or .prow_ci.env) to build the OLM upgrade index" >&2
      exit 1
    fi
    # Pin to the channel install_yamls subscribes to (alpha); channel names are
    # unique per package, so this matches exactly one head.
    OPERATOR_CHANNEL=${OPERATOR_CHANNEL:-alpha}
    # Render the base index once and pull the channel head CSV and its bundle out.
    BASE_RENDER=$(opm render "${OPENSTACK_IMG_BASE_RELEASE}")
    BASE_CSV=$(echo "$BASE_RENDER" | jq -r --arg ch "$OPERATOR_CHANNEL" 'select(.schema=="olm.channel" and .package=="openstack-operator" and .name==$ch) | .entries[-1].name')
    # set -ex has no pipefail, so a failed opm/jq yields an empty BASE_CSV and a
    # silent no-op upgrade edge; fail fast instead.
    if [[ -z "$BASE_CSV" ]]; then
      echo "Could not derive base CSV (channel head) from ${OPENSTACK_IMG_BASE_RELEASE}" >&2
      exit 1
    fi
    # The base bundle is added directly to a fresh index below (not --from-index),
    # so pull its image ref from the render too.
    BASE_RELEASE_BUNDLE=$(echo "$BASE_RENDER" | jq -r --arg csv "$BASE_CSV" 'select(.schema=="olm.bundle" and .name==$csv) | .image')
    if [[ -z "$BASE_RELEASE_BUNDLE" ]]; then
      echo "Could not derive base bundle image for ${BASE_CSV} from ${OPENSTACK_IMG_BASE_RELEASE}" >&2
      exit 1
    fi
    export REPLACES=${BASE_CSV}
    MAKE_VERSION=$(grep -E '^VERSION[[:space:]]*\??=' Makefile | head -1 | sed -E 's/.*=[[:space:]]*//; s/[[:space:]#].*//')
    if [[ -z "$MAKE_VERSION" ]]; then
      echo "Could not read VERSION from openstack-operator Makefile" >&2
      exit 1
    fi
    export VERSION=${MAKE_VERSION%.*}.99
  fi

  if [[ "$OPERATOR" == "$META_OPERATOR" ]]; then
    GOWORK='' make manifests bindata
  fi

  GOWORK='' make build

  # Build and push operator image
  oc new-build --binary --strategy=docker --name ${OPERATOR} --to=${IMAGE_TAG_BASE}:${IMAGE_TAG} --push-secret=${PUSH_REGISTRY_SECRET} --to-docker=true
  oc set build-secret --pull bc/${OPERATOR} ${DOCKER_REGISTRY_SECRET}
  oc start-build ${OPERATOR} --from-dir . -F
  check_build_result ${OPERATOR}

  GOWORK='' make bundle

  # Hand the OLM upgrade edge to the deploy/kuttl/chainsaw steps: the base
  # release channel head and the PR bundle CSV (read from the generated manifest,
  # so it is the exact version OLM will see) drive STARTING_CSV / approvals.
  if [[ "$OPERATOR" == "$META_OPERATOR" ]]; then
    PR_CSV=$(awk '/^  name: openstack-operator\.v/{print $2; exit}' bundle/manifests/openstack-operator.clusterserviceversion.yaml)
    if [[ -z "$PR_CSV" || "$PR_CSV" == "$BASE_CSV" ]]; then
      echo "PR bundle CSV (${PR_CSV:-empty}) must exist and differ from base ${BASE_CSV}; the operator VERSION must be higher than the OPENSTACK_IMG_BASE_RELEASE version" >&2
      exit 1
    fi
    echo "${BASE_CSV}" > "${SHARED_DIR}/olm-base-csv"
    echo "${PR_CSV}" > "${SHARED_DIR}/olm-pr-csv"
  fi

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

  # Enable webhooks in Prow CI Job builds
  oc patch bc/${OPERATOR}-bundle \
    --type='json' \
    -p='[{"op": "add", "path": "/spec/strategy/dockerStrategy/env", "value": [{"name": "ENABLE_WEBHOOKS", "value": "true"}]}]'

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
    # Fresh index holding the base and PR bundles with a base -> PR upgrade edge.
    # --mode semver derives that edge from the version order (base < PR, the PR is
    # the operator major.minor with a .99 patch so it always sorts above the base),
    # so it does not depend on a spec.replaces field in the generated PR bundle. The
    # base bundle is added directly rather than via --from-index, whose deprecated
    # sqlite prune rejects the File-Based Catalog base index.
    opm index add --mode semver --bundles "${BASE_RELEASE_BUNDLE},${BASE_BUNDLE}${OPENSTACK_BUNDLES}" --out-dockerfile "${INDEX_DOCKERFILE}" --generate
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
oc create secret generic ${PUSH_REGISTRY_SECRET} --from-file=.dockerconfigjson=${PUSH_REGISTRY_SECRET_PATH}/config.json --type=kubernetes.io/dockerconfigjson

# Build operator
IMAGE_TAG_BASE=${PUSH_REGISTRY}/${PUSH_ORGANIZATION}/${BASE_OP}
BUILD_TAG="${PR_SHA:0:20}-${PROW_BUILD}"

build_push_operator_images "${BASE_OP}" "${BASE_DIR}/${BASE_OP}" "${IMAGE_TAG_BASE}" "${BUILD_TAG}"

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
    # before operator-sdk 1.41 bump, api module is in apis, later it is in api
    if [ -d "./apis" ]; then
      pushd ./apis/
    else
      pushd ./api/
    fi
    go mod edit -replace github.com/${DEFAULT_ORG}/${BASE_OP}/${API_MOD}=github.com/${REPO_NAME}/${API_MOD}@${API_SHA}
    go mod tidy
    popd
  fi

  # Variables needed to pull service operator built in this job
  export IMAGENAMESPACE=${PUSH_ORGANIZATION}
  export IMAGEREGISTRY=${PUSH_REGISTRY}
  export IMAGEBASE=${SERVICE_NAME}
  export IMAGECUSTOMTAG=${BUILD_TAG}

  # Build openstack-operator bundle and index
  IMAGE_TAG_BASE=${PUSH_REGISTRY}/${PUSH_ORGANIZATION}/${META_OPERATOR}
  build_push_operator_images "${META_OPERATOR}" "${BASE_DIR}/${META_OPERATOR}" "${IMAGE_TAG_BASE}" "${BUILD_TAG}"

  popd
  popd
fi
