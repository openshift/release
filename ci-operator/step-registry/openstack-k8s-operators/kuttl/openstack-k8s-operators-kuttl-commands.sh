#!/usr/bin/env bash

set -ex

ORG="openstack-k8s-operators"

# We don't want to use OpenShift-CI build cluster namespace
unset NAMESPACE

# Check org and project from job's spec
REF_REPO=$(echo ${JOB_SPEC} | jq -r '.refs.repo')
REF_ORG=$(echo ${JOB_SPEC} | jq -r '.refs.org')
# PR SHA
PR_SHA=$(echo ${JOB_SPEC} | jq -r '.refs.pulls[0].sha')

# Fails if step is not being used on openstack-k8s-operators repos
# Gets base repo name
BASE_OP=${REF_REPO}
if [[ "$REF_ORG" != "$ORG" ]]; then
    echo "Not a ${ORG} job. Checking if isn't a rehearsal job..."
    EXTRA_REF_REPO=$(echo ${JOB_SPEC} | jq -r '.extra_refs[0].repo')
    EXTRA_REF_ORG=$(echo ${JOB_SPEC} | jq -r '.extra_refs[0].org')
    #EXTRA_REF_BASE_REF=$(echo ${JOB_SPEC} | jq -r '.extra_refs[0].base_ref')
    if [[ "$EXTRA_REF_ORG" != "$ORG" ]]; then
      echo "Failing since this step supports only ${ORG} changes."
      exit 1
    fi
    BASE_OP=${EXTRA_REF_REPO}
else

fi

SERVICE_NAME=$(echo "${BASE_OP}" | sed 's/\(.*\)-operator/\1/')

export IMAGE_TAG_BASE=${REGISTRY}/${ORGANIZATION}/${SERVICE_NAME}-operator
export ${SERVICE_NAME^^}_IMG=${IMAGE_TAG_BASE}-index:${PR_SHA}
export ${SERVICE_NAME^^}_KUTTL_CONF=/go/src/github.com/${ORG}/${BASE_OP}/kuttl-test.yaml
export ${SERVICE_NAME^^}_KUTTL_DIR=/go/src/github.com/${ORG}/${BASE_OP}/tests/kuttl/tests


if [ -f "/go/src/github.com/${ORG}/${BASE_OP}/kuttl-test.yaml" ]; then
  if [ ! -d "${HOME}/install_yamls" ]; then
    cd ${HOME}
    git clone https://github.com/openstack-k8s-operators/install_yamls.git
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
else
  echo "File /go/src/github.com/${ORG}/${BASE_OP}/kuttl-test.yaml not found. Skipping script."
fi
