#!/usr/bin/env bash

set -ex

DEFAULT_ORG="openstack-k8s-operators"
BASE_DIR=${HOME:-"/alabama"}
NS_OPERATORS=${NS_OPERATORS:-"openstack-operators"}
NS_SERVICES=${NS_SERVICES:-"openstack"}

# We don't want to use OpenShift-CI build cluster namespace
export NAMESPACE=${NS_SERVICES}
export OPERATOR_NAMESPACE=${NS_OPERATORS}

function enable_secret_docker_pull {
  local ns=${1}
  DOCKER_REGISTRY_SECRET=pull-docker-secret
  oc -n ${ns} create secret generic ${DOCKER_REGISTRY_SECRET} --from-file=.dockerconfigjson=/secrets/docker/config.json --type=kubernetes.io/dockerconfigjson
  oc -n ${ns} secrets link default ${DOCKER_REGISTRY_SECRET} --for=pull
}

# Check org and project from job's spec
REF_REPO=$(echo ${JOB_SPEC} | jq -r '.refs.repo')
REF_ORG=$(echo ${JOB_SPEC} | jq -r '.refs.org')

# Fails if step is not being used on openstack-k8s-operators repos
# Gets base repo name
BASE_OP=${REF_REPO}
if [[ "$REF_ORG" != "$DEFAULT_ORG" ]]; then
    echo "Not a ${DEFAULT_ORG} job. Checking if isn't a rehearsal job..."
    EXTRA_REF_REPO=$(echo ${JOB_SPEC} | jq -r '.extra_refs[0].repo')
    EXTRA_REF_ORG=$(echo ${JOB_SPEC} | jq -r '.extra_refs[0].org')
    if [[ "$EXTRA_REF_ORG" != "$DEFAULT_ORG" ]]; then
      echo "Failing since this step supports only ${DEFAULT_ORG} changes."
      exit 1
    fi
    BASE_OP=${EXTRA_REF_REPO}
fi
SERVICE_NAME=$(echo "${BASE_OP}" | sed 's/\(.*\)-operator/\1/')

function create_namespaces {
  pushd ${BASE_DIR}
  if [ ! -d "./install_yamls" ]; then
    git clone https://github.com/openstack-k8s-operators/install_yamls.git
  fi
  cd install_yamls
  make namespace
  make operator_namespace
  popd
}

create_namespaces

# Enable secrets for docker pull
enable_secret_docker_pull ${NS_SERVICES}
if [[ "$NS_SERVICES" != "$NS_OPERATORS" ]]; then
  enable_secret_docker_pull ${NS_OPERATORS}
fi

# Create kuttl namespace
NS_KUTTL=${NS_KUTTL:-${SERVICE_NAME}-kuttl-tests}
export NAMESPACE=${NS_KUTTL}
create_namespaces
# secret for pulling containers from docker
enable_secret_docker_pull ${NAMESPACE}
export NAMESPACE=${NS_SERVICES}
