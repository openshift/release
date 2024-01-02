#!/usr/bin/env bash

set -ex

META_OPERATOR="openstack-operator"
ORG="openstack-k8s-operators"
# Export Ceph options for tests that call 'make ceph'
export CEPH_HOSTNETWORK=${CEPH_HOSTNETWORK:-"true"}
export CEPH_DATASIZE=${CEPH_DATASIZE:="2Gi"}
export CEPH_TIMEOUT=${CEPH_TIMEOUT:="90"}

# We don't want to use OpenShift-CI build cluster namespace
unset NAMESPACE

# Check org and project from job's spec
REF_REPO=$(echo ${JOB_SPEC} | jq -r '.refs.repo')
REF_ORG=$(echo ${JOB_SPEC} | jq -r '.refs.org')
REF_BRANCH=$(echo ${JOB_SPEC} | jq -r '.refs.base_ref')

# PR SHA
PR_SHA=$(echo ${JOB_SPEC} | jq -r '.refs.pulls[0].sha')

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
export KUTTL_REPORT=kuttl-test-${SERVICE_NAME}.json
export NETWORK_ISOLATION=false
if [ ${SERVICE_NAME} == "openstack-ansibleee" ]; then
    # the service_name needs to be different to use in the image url than in
    # the environment variables
    export IMAGE_TAG_BASE=${REGISTRY}/${ORGANIZATION}/openstack-ansibleee-operator
    export KUTTL_REPORT=kuttl-test-openstack-ansibleee.json
    SERVICE_NAME=ansibleee
fi


export ${SERVICE_NAME^^}_IMG=${IMAGE_TAG_BASE}-index:${PR_SHA}
export ${SERVICE_NAME^^}_KUTTL_CONF=/go/src/github.com/${ORG}/${BASE_OP}/kuttl-test.yaml
if [ -d  /go/src/github.com/${ORG}/${BASE_OP}/tests ]; then
    export ${SERVICE_NAME^^}_KUTTL_DIR=/go/src/github.com/${ORG}/${BASE_OP}/tests/kuttl/tests
else
    # some projects (like neutron) had a test folder before adding the kuttl
    # tests, so they were added there to avoid having both 'test' and 'tests'
    # folders
    export ${SERVICE_NAME^^}_KUTTL_DIR=/go/src/github.com/${ORG}/${BASE_OP}/test/kuttl/tests
fi
# make sure that the operator_deploy steps use the PR code (needed to test CR
# changes in the PR)
export ${SERVICE_NAME^^}_REPO=/go/src/github.com/${ORG}/${BASE_OP}

# Use built META_OPERATOR bundle image
export OPENSTACK_BUNDLE_IMG=${REGISTRY}/${ORGANIZATION}/${META_OPERATOR}-bundle:${PR_SHA}

if [ -f "/go/src/github.com/${ORG}/${BASE_OP}/kuttl-test.yaml" ]; then
  if [ ! -d "${HOME}/install_yamls" ]; then
    cd ${HOME}
    git clone https://github.com/openstack-k8s-operators/install_yamls.git -b ${REF_BRANCH}
  fi

  cd ${HOME}/install_yamls
  # Create/enable openstack namespace
  make namespace
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

  make ${SERVICE_NAME}_kuttl
  if [ -f "$KUTTL_REPORT" ]; then
      cp "${KUTTL_REPORT}" ${ARTIFACT_DIR}
  else
      echo "Report ${KUTTL_REPORT} not found"
  fi
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
else
  echo "File /go/src/github.com/${ORG}/${BASE_OP}/kuttl-test.yaml not found. Skipping script."
fi
