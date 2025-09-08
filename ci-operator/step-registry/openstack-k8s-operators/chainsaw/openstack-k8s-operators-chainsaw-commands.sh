#!/usr/bin/env bash

set -ex

storage_create () {
  # Creates storage
  # Sometimes it fails to find container-00 inside debug pod
  # TODO: fix issue in install_yamls
  n=0
  retries=3
  while true; do
    make crc_storage && break
    n=$((n+1))
    if (( n >= retries )); then
      echo "Failed to run 'make crc_storage' target. Aborting"
      exit 1
    fi
    sleep 10
  done
}

storage_cleanup () {
  # Run storage cleanup otherwise we can hit random issue during deploy step where
  # mariadb pod will use the same pv which have a db already and fails because
  # The init job assumed that the DB was just created and had an empty root password,
  # which would not be the case.
  n=0
  retries=3
  while (( n < retries )); do
    if make crc_storage_cleanup; then
      break
    fi
    n=$((n+1))
    echo "Failed to run 'make crc_storage_cleanup' target (attempt $n of $retries)"
    sleep 10
  done
}


META_OPERATOR="openstack-operator"
ORG="openstack-k8s-operators"
# Export Ceph options for tests that call 'make ceph'
export CEPH_HOSTNETWORK=${CEPH_HOSTNETWORK:-"true"}
export CEPH_DATASIZE=${CEPH_DATASIZE:="8Gi"}
export CEPH_TIMEOUT=${CEPH_TIMEOUT:="90"}

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
# Build tag
BUILD_TAG="${PR_SHA:0:20}-${PROW_BUILD}"

# Fails if step is not being used on openstack-k8s-operators repos
# Gets base repo name
BASE_OP=${REF_REPO}
if [[ "$REF_ORG" != "$ORG" ]]; then
    echo "Not a ${ORG} job. Checking if isn't a rehearsal job..."
    EXTRA_REF_REPO=$(echo ${JOB_SPEC} | jq -r '.extra_refs[0].repo')
    EXTRA_REF_ORG=$(echo ${JOB_SPEC} | jq -r '.extra_refs[0].org')
    REF_BRANCH=$(echo ${JOB_SPEC} | jq -r '.extra_refs[0].base_ref')
    if [[ "$EXTRA_REF_ORG" != "$ORG" ]]; then
      echo "Failing since this step supports only ${ORG} changes."
      exit 1
    fi
    BASE_OP=${EXTRA_REF_REPO}
fi
# sets default branch for install_yamls
export OPENSTACK_K8S_BRANCH=${REF_BRANCH}

# custom per project ENV variables
# shellcheck source=/dev/null
if [ -f /go/src/github.com/${ORG}/${BASE_OP}/.prow_ci.env ]; then
  source /go/src/github.com/${ORG}/${BASE_OP}/.prow_ci.env
fi

SERVICE_NAME=$(echo "${BASE_OP}" | sed 's/\(.*\)-operator/\1/')
export IMAGE_TAG_BASE=${REGISTRY}/${ORGANIZATION}/${SERVICE_NAME}-operator
export CHAINSAW_REPORT=chainsaw-report.json
export NETWORK_ISOLATION=false
export INSTALL_NNCP=false
export INSTALL_NMSTATE=false
if [ ${SERVICE_NAME} == "openstack-ansibleee" ]; then
    # the service_name needs to be different to use in the image url than in
    # the environment variables
    export IMAGE_TAG_BASE=${REGISTRY}/${ORGANIZATION}/openstack-ansibleee-operator
    SERVICE_NAME=ansibleee
fi


export ${SERVICE_NAME^^}_IMG=${IMAGE_TAG_BASE}-index:${BUILD_TAG}
export ${SERVICE_NAME^^}_CHAINSAW_CONF=/go/src/github.com/${ORG}/${BASE_OP}/tests/chainsaw/config.yaml
export ${SERVICE_NAME^^}_CHAINSAW_DIR=/go/src/github.com/${ORG}/${BASE_OP}/tests/chainsaw/tests

# make sure that the operator_deploy steps use the PR code (needed to test CR
# changes in the PR)
export ${SERVICE_NAME^^}_REPO=/go/src/github.com/${ORG}/${BASE_OP}

# Use built META_OPERATOR index image
# This is required by dataplane chainsaw tests which installs openstack-operator
export OPENSTACK_IMG=${REGISTRY}/${ORGANIZATION}/${META_OPERATOR}-index:${BUILD_TAG}

# Use built META_OPERATOR bundle image
export OPENSTACK_BUNDLE_IMG=${REGISTRY}/${ORGANIZATION}/${META_OPERATOR}-bundle:${BUILD_TAG}

if [ -f "/go/src/github.com/${ORG}/${BASE_OP}/tests/chainsaw/config.yaml" ]; then
  if [ ! -d "${HOME}/install_yamls" ]; then
    cd ${HOME}
    git clone https://github.com/openstack-k8s-operators/install_yamls.git -b ${REF_BRANCH}
  fi

  cd ${HOME}/install_yamls
  # set slow etcd profile
  make set_slower_etcd_profile
  # Create/enable openstack namespace
  make namespace

  storage_create

  # perform a minor update if it is the openstack-operator
  if [ ${SERVICE_NAME} == "openstack" ]; then
    OPENSTACK_IMG_BKP=${OPENSTACK_IMG}

    # deploy operators and ctlplane, to be updated
    export OPENSTACK_IMG=${OPENSTACK_IMG_BASE_RELEASE:="quay.io/openstack-k8s-operators/openstack-operator-index:87ab1f1fa16743cad640f994f459ef14c5d2b9ca"}
    export TIMEOUT=${TIMEOUT:="600s"}
    make openstack_wait || exit 1

    # if the new initialization resource exists install it
    # this will also wait for operators to deploy
    if oc get crd openstacks.operator.openstack.org &> /dev/null; then
      make openstack_init
    fi

    make openstack_wait_deploy || exit 1
    # Create the dataplane CRs to check their update
    make edpm_deploy_baremetal || exit 1
    make openstack_cleanup || exit 1

    # update operators and ctlplane to the PR
    export OPENSTACK_IMG=${OPENSTACK_IMG_BKP}
    make openstack_wait || exit 1
    sleep 10
    # if the new initialization resource exists install it
    # this will also wait for operators to deploy
    if oc get crd openstacks.operator.openstack.org &> /dev/null; then
      make openstack_init
    fi
    make openstack_patch_version || exit 1
    sleep 10
    oc wait openstackcontrolplane -n openstack --for=condition=Ready --timeout=${TIMEOUT} -l core.openstack.org/openstackcontrolplane || exit 1

    # cleanup to run chainsaw
    make edpm_deploy_cleanup openstack_deploy_cleanup && \
    oc wait -n openstack --for=delete pod/swift-storage-0 --timeout=${TIMEOUT}
    storage_cleanup && storage_create
  fi

  # run chainsaw
  make ${SERVICE_NAME}_chainsaw

  if [ -f "$CHAINSAW_REPORT" ]; then
      cp "${CHAINSAW_REPORT}" ${ARTIFACT_DIR}
  else
      echo "Report ${CHAINSAW_REPORT} not found"
  fi

  storage_cleanup
else
  echo "File /go/src/github.com/${ORG}/${BASE_OP}/tests/chainsaw/config.yaml not found. Skipping script."
fi
