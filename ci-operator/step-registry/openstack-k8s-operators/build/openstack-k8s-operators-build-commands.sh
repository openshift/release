#!/usr/bin/env bash

set -ex

#DEBUG
env

unset NAMESPACE
export BASE=`echo $JOB_SPEC | jq -r '.extra_refs[0].repo'`
export SHA=`echo $JOB_SPEC | jq  -r '.refs.pulls[0].sha'`

cp -r /go/src/github.com/openstack-k8s-operators/${BASE}/ ${HOME}
# Creating openstack namespace
cd ${HOME}
git clone https://github.com/openstack-k8s-operators/install_yamls.git
cd install_yamls
make namespace

# Secret for pushing containers
export REGISTRY_SECRET=secret-quay
oc create secret generic ${REGISTRY_SECRET} --from-file=.dockerconfigjson=/secrets/docker/config.json --type=kubernetes.io/dockerconfigjson

###
export OS_REGISTRY=quay.io
export OS_REPO=dviroel
export IMAGE_TAG_BASE=${OS_REGISTRY}/${OS_REPO}/${BASE}
export VERSION=0.0.1
export IMG=$IMAGE_TAG_BASE:$SHA

# Build bundle
cd ${HOME}/${BASE}
make build bundle

# Operator image
oc new-build --binary --strategy=docker --name ${BASE} --to=${IMAGE_TAG_BASE}:${SHA} --push-secret=${REGISTRY_SECRET} --to-docker=true
oc start-build ${BASE} --from-dir . -F

# Bundle image
oc new-build --binary --strategy=docker --name ${BASE}-bundle --to=${IMAGE_TAG_BASE}-bundle:${SHA} --push-secret=${REGISTRY_SECRET} --to-docker=true
oc patch bc ${BASE}-bundle -p '{"spec":{"strategy":{"dockerStrategy":{"dockerfilePath":"bundle.Dockerfile"}}}}'
oc start-build ${BASE}-bundle --from-dir . -F

# Catalog image
export BASE_BUNDLE=${IMAGE_TAG_BASE}-bundle:${SHA}
opm index add --bundles "${BASE_BUNDLE}" --out-dockerfile index.Dockerfile --generate

oc new-build --binary --strategy=docker --name ${BASE}-index --to=${IMAGE_TAG_BASE}-index:${SHA} --push-secret=${REGISTRY_SECRET} --to-docker=true
oc patch bc ${BASE}-index -p '{"spec":{"strategy":{"dockerStrategy":{"dockerfilePath":"index.Dockerfile"}}}}'
oc start-build ${BASE}-index --from-dir . -F

# OpenStack operator (meta-operator)
cd ${HOME}
git clone https://github.com/openstack-k8s-operators/openstack-operator.git
cd openstack-operator

export OPENSTACK_OPERATOR=openstack-operator
export IMAGE_TAG_BASE=${OS_REGISTRY}/${OS_REPO}/${OPENSTACK_OPERATOR}
export VERSION=0.0.1
export IMG=$IMAGE_TAG_BASE:$SHA

make build bundle

# Operator image
oc new-build --binary --strategy=docker --name ${OPENSTACK_OPERATOR} --to=${IMAGE_TAG_BASE}:${SHA} --push-secret=${REGISTRY_SECRET} --to-docker=true
oc start-build ${OPENSTACK_OPERATOR} --from-dir . -F

# Bundle image
oc new-build --binary --strategy=docker --name ${OPENSTACK_OPERATOR}-bundle --to=${IMAGE_TAG_BASE}-bundle:${SHA} --push-secret=${REGISTRY_SECRET} --to-docker=true
oc patch bc ${OPENSTACK_OPERATOR}-bundle -p '{"spec":{"strategy":{"dockerStrategy":{"dockerfilePath":"custom-bundle.Dockerfile.pinned"}}}}'
oc start-build ${OPENSTACK_OPERATOR}-bundle --from-dir . -F

# Catalog image
export OPENSTACK_OPERATOR_BUNDLE=${IMAGE_TAG_BASE}-bundle:${SHA}
opm index add --bundles "${OPENSTACK_OPERATOR_BUNDLE}" --out-dockerfile index.Dockerfile --generate

oc new-build --binary --strategy=docker --name ${OPENSTACK_OPERATOR}-index --to=${IMAGE_TAG_BASE}-index:${SHA} --push-secret=${REGISTRY_SECRET} --to-docker=true
oc patch bc ${OPENSTACK_OPERATOR}-index -p '{"spec":{"strategy":{"dockerStrategy":{"dockerfilePath":"index.Dockerfile"}}}}'
oc start-build ${OPENSTACK_OPERATOR}-index --from-dir . -F

#echo "${IMAGE_TAG_BASE}-index:${SHA}" > ${SHARED_DIR}/OPENSTACK_OPERATOR_INDEX