#!/usr/bin/env bash

set -ex

# TODO(dviroel): extend build step to build all other openstack-k8s-operators
ORG="openstack-k8s-operators"
BASE="openstack-operator"

# We don't want to use OpenShift-CI build cluster namespace
unset NAMESPACE

# Check org and project from job's spec
REF_BASE=$(echo ${JOB_SPEC} | jq -r '.refs.repo')
REF_ORG=$(echo ${JOB_SPEC} | jq -r '.refs.org')
# PR SHA
PR_SHA=$(echo ${JOB_SPEC} | jq -r '.refs.pulls[0].sha')

# Fail if this step is being used for testing a repo != openstack-operator
if [[ "$REF_ORG" != "$ORG" || "$REF_BASE" != "$BASE" ]]; then
    echo "Not a ${BASE} job. Checking if isn't a rehearsal job..."
    EXTRA_REF_BASE=$(echo ${JOB_SPEC} | jq -r '.extra_refs[0].repo')
    EXTRA_REF_ORG=$(echo ${JOB_SPEC} | jq -r '.extra_refs[0].org')
    echo $EXTRA_REF_BASE
    echo $EXTRA_REF_ORG
    if [[ "$EXTRA_REF_ORG" != "$ORG" || "$EXTRA_REF_BASE" != "$BASE" ]]; then
      echo "Failing since this step supports only ${BASE} changes."
      exit 1
    fi
fi

# Copy base operator code to user's home directory
cp -r /go/src/github.com/${ORG}/${BASE}/ ${HOME}

# Creating/enabling openstack namespace
cd ${HOME}
git clone https://github.com/openstack-k8s-operators/install_yamls.git
cd install_yamls
make namespace

# Secret for pushing containers - openstack namespace
REGISTRY_SECRET=push-quay-secret
oc create secret generic ${REGISTRY_SECRET} --from-file=.dockerconfigjson=/secrets/docker/config.json --type=kubernetes.io/dockerconfigjson

# Build operator
IMAGE_TAG_BASE=${REGISTRY}/${ORGANIZATION}/${BASE}
export VERSION=0.0.1
export IMG=$IMAGE_TAG_BASE:${PR_SHA}

# Build bin and bundle content
unset GOFLAGS
cd ${HOME}/${BASE}
make build bundle

# Build and push operator image
oc new-build --binary --strategy=docker --name ${BASE} --to=${IMAGE_TAG_BASE}:${PR_SHA} --push-secret=${REGISTRY_SECRET} --to-docker=true
oc start-build ${BASE} --from-dir . -F

# Build and push bundle image
oc new-build --binary --strategy=docker --name ${BASE}-bundle --to=${IMAGE_TAG_BASE}-bundle:${PR_SHA} --push-secret=${REGISTRY_SECRET} --to-docker=true
oc patch bc ${BASE}-bundle -p '{"spec":{"strategy":{"dockerStrategy":{"dockerfilePath":"custom-bundle.Dockerfile.pinned"}}}}'
oc start-build ${BASE}-bundle --from-dir . -F

# Generate, build and push image catalog image
export BASE_BUNDLE=${IMAGE_TAG_BASE}-bundle:${PR_SHA}
opm index add --bundles "${BASE_BUNDLE}" --out-dockerfile index.Dockerfile --generate

oc new-build --binary --strategy=docker --name ${BASE}-index --to=${IMAGE_TAG_BASE}-index:${PR_SHA} --push-secret=${REGISTRY_SECRET} --to-docker=true
oc patch bc ${BASE}-index -p '{"spec":{"strategy":{"dockerStrategy":{"dockerfilePath":"index.Dockerfile"}}}}'
oc start-build ${BASE}-index --from-dir . -F
